Path: Path A - full
ECS and Application Auto Scaling both supported.

## Review Question 2
Two entirely different compute services - an EC2 instance (usms-web-01 via instance profile) and a Fargate task (via taskRoleArn) - hold the same permission policy (USMSStudentDataReadWrite). Neither compute resource holds an API key on disk, and neither policy needed modification. Both will gain access to arn:aws:s3:::usms-student-data simultaneously when the bucket is created in Lab 10.
