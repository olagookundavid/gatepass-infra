# WHAT KEDA MAY DO IN AWS: read the length of the three queues its ScaledObjects watch. Nothing else.
#
# KEDA (platform add-on, bootstrap/keda.yaml) scales a worker Deployment by the number of messages waiting
# in its SQS queue. To count them it calls sqs:GetQueueAttributes (ApproximateNumberOfMessages and the
# in-flight / delayed counts). That is a READ of metadata: it does not receive, delete or read a message,
# and it needs no KMS permission (the queues are encrypted with our key, but attributes are not message
# bodies). The role belongs to the OPERATOR pod (service account keda-operator in namespace keda); the
# ScaledObjects reach it through the ClusterTriggerAuthentication keda-aws-operator
# (gatepass-gitops platform/cluster-config/keda-trigger-auth.yaml, `identityOwner: keda`).
#
# THE QUEUES ARE LISTED BY NAME, not "all queues": a compromised KEDA could learn how busy three queues
# are and nothing more (it could not touch the Karpenter interruption queue or the dead-letter queues).
# Adding a worker that scales on a new queue is a pull request here (data.tf lists the queues).
#
# Related files: pod-identity.tf (the role and its association), data.tf (the queue lookups).

data "aws_iam_policy_document" "keda" {
  statement {
    sid       = "ReadQueueLengthOfTheScaledQueues"
    effect    = "Allow"
    actions   = ["sqs:GetQueueAttributes"]
    resources = [for q in data.aws_sqs_queue.scaled : q.arn]
  }
}

resource "aws_iam_role_policy" "keda" {
  name   = "read-queue-length"
  role   = aws_iam_role.workload["keda"].id
  policy = data.aws_iam_policy_document.keda.json
}
