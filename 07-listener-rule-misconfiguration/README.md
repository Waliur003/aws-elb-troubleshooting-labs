# Lab 07 — ALB Listener Rule Misconfiguration

## Overview

This lab demonstrates how to troubleshoot an AWS Application Load Balancer (ALB) that forwards requests to the wrong target group because of a misconfigured listener rule.

We deploy an internet-facing ALB with an Amazon EC2 backend running a Python HTTP application on port 8080.

The application supports three endpoints: `/`, `/app`, and `/health`.

We create two target groups. The first target group contains a healthy EC2 instance, while the second target group remains empty.

Initially, the ALB listener forwards all requests to the healthy application target group.

We then intentionally introduce a priority 10 listener rule that forwards `/app` requests to the empty target group.

As a result, requests to `/app` return HTTP 503 Service Unavailable, while requests to `/` continue returning HTTP 200.

We investigate listener rule priorities, forwarding actions, target group ARNs, registered targets, backend health, and CloudWatch metrics.

After identifying the incorrect forwarding rule, we modify its action to use the correct target group and verify that application requests succeed.

**Workflow:** Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Details |
|---|---|
| Incident ID | INC-ELB-007 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, EC2, VPC, IAM, Systems Manager, CloudWatch |
| Load Balancer | Application Load Balancer |
| Scheme | Internet-facing |
| Listener | HTTP 80 |
| Backend | Amazon Linux 2023, `t3.micro` |
| Backend Application | Python HTTP Server |
| Application Port | 8080 |
| Correct Target Group | `cloud-elb-lab07-app-tg` |
| Incorrect Target Group | `cloud-elb-lab07-wrong-tg` |
| Health Check | `/health` |
| Application Endpoint | `/app` |
| Listener Rule Priority | 10 |
| Fault Injection | Forward `/app` to empty target group |
| Error | HTTP 503 Service Unavailable |
| Root Cause | Incorrect listener forwarding action |
| Remediation | Update listener rule target group |
| Verification | HTTP 200 on all application endpoints |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts a web application behind an AWS Application Load Balancer.

The application runs on an EC2 instance and listens on port 8080.

The ALB has an HTTP listener on port 80.

The listener's default action forwards requests to a target group containing a healthy EC2 instance.

During an infrastructure configuration update, an engineer accidentally creates a path-based listener rule that forwards `/app` requests to another target group.

The second target group has no registered targets.

After the configuration change, the home page continues working, but requests to `/app` return HTTP 503 Service Unavailable.

The cloud engineering team must identify why only one application route is affected and correct the listener rule without changing the working backend application.

### Incident Symptoms

- ALB remains active.
- EC2 instance remains running.
- Backend application remains active.
- Correct target group reports a healthy EC2 target.
- Incorrect target group contains zero registered targets.
- HTTP listener default action forwards correctly.
- Priority 10 rule forwards `/app` to the wrong target group.
- `/` returns HTTP 200.
- `/health` returns HTTP 200.
- `/app` returns HTTP 503.

### Potential Business Impact

- Application endpoints become unavailable.
- Customer requests fail.
- API clients receive HTTP 503 errors.
- Partial application outages become difficult to diagnose.
- Monitoring may report increased ALB-generated 503 responses.
- Healthy infrastructure may appear operational while specific routes remain broken.

### Objective

Identify why the ALB returns HTTP 503 for `/app` even though the backend is healthy, correct the listener forwarding rule, and restore successful application requests.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                       Internet Client
                              |
                              v
                   +---------------------+
                   | Application Load    |
                   | Balancer            |
                   | HTTP Listener: 80   |
                   +----------+----------+
                              |
                              v
                    Default Forward Rule
                              |
                              v
                   +---------------------+
                   | Application Target  |
                   | Group               |
                   | HTTP Port: 8080     |
                   | Registered: 1       |
                   +----------+----------+
                              |
                              v
                   +---------------------+
                   | EC2 Backend         |
                   | Python HTTP Server  |
                   | Port: 8080          |
                   +----------+----------+
                              |
                              v
                         HTTP 200 OK
```

### Broken Architecture

```text
                       Internet Client
                              |
                              v
                   Application Load Balancer
                              |
                              v
                       HTTP Listener: 80
                              |
                    +---------+---------+
                    |                   |
                    v                   v
               Default Rule       Priority 10 Rule
                    |               Path: /app
                    |                   |
                    v                   v
             Correct Target       Wrong Target
                  Group                Group
                    |                   |
                    v                   v
              Healthy EC2       Registered Targets: 0
                    |                   |
                    v                   v
                HTTP 200             HTTP 503
```

### Infrastructure Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.166.0.0/16` |
| Subnet A | `10.166.1.0/24` |
| Subnet B | `10.166.2.0/24` |
| Internet Gateway | Attached |
| ALB Security Group | HTTP 80 from internet |
| Backend Security Group | TCP 8080 from ALB SG |
| ALB Listener | HTTP 80 |
| Correct Target Group | HTTP 8080, one healthy target |
| Wrong Target Group | HTTP 8080, zero targets |
| Health Check | `/health` |
| Listener Rule | Priority 10, path `/app` |

---

## 4. Understanding ALB Listener Rules

An Application Load Balancer uses listener rules to determine how incoming HTTP or HTTPS requests should be handled.

Rules can evaluate request properties such as:

- URL path
- Hostname
- HTTP headers
- HTTP request methods
- Query strings
- Source IP addresses

When multiple rules exist, the ALB evaluates nondefault rules in ascending numerical priority order.

The default rule is evaluated last.

### Example Rule Configuration

```text
Priority: 10
Condition: Path = /app
Action: Forward to wrong target group

Priority: default
Condition: All remaining requests
Action: Forward to correct target group
```

### Request Routing

| Request | Matching Rule | Target Group |
|---|---|---|
| `/` | Default | Correct TG |
| `/health` | Default | Correct TG |
| `/app` | Priority 10 | Wrong TG |

### Why Does HTTP 503 Occur?

The rule for `/app` forwards the request to a target group that has no registered targets.

The ALB cannot select a backend and generates HTTP 503 Service Unavailable.

### Important Concept

A healthy target group does not guarantee that all application routes work.

The listener must forward each request to the correct target group.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- EC2 permissions
- VPC permissions
- Elastic Load Balancing permissions
- IAM permissions
- Systems Manager access
- CloudWatch read permissions
- Git and GitHub

### Security Requirements

- Use a dedicated test VPC.
- Do not modify production listeners for testing.
- Restrict backend access to the ALB security group.
- Use least-privilege IAM permissions.
- Verify resource ownership before cleanup.
- Do not commit credentials or private keys.

### Cost Considerations

Resources that may incur charges include:

- Application Load Balancer
- Load Balancer Capacity Units
- EC2 instance
- EBS storage
- Public IPv4 address
- Applicable data transfer

Clean up temporary resources after finishing the exercise.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab07"

export VPC_CIDR="10.166.0.0/16"
export SUBNET_A_CIDR="10.166.1.0/24"
export SUBNET_B_CIDR="10.166.2.0/24"

export ALB_NAME="cloud-elb-lab07-alb"

export APP_TG_NAME="cloud-elb-lab07-app-tg"
export WRONG_TG_NAME="cloud-elb-lab07-wrong-tg"

export ROLE_NAME="cloud-elb-lab07-ssm-role"
export PROFILE_NAME="cloud-elb-lab07-ssm-profile"
```

Verify identity:

```bash
aws sts get-caller-identity
aws --version
```

### Step 2 — Select Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Choose two supported AZs:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 3 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' \
  --output table \
  --region "$AWS_REGION"

aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

A `LoadBalancerNotFound` result is expected for an unused ALB name.

Avoid creating duplicate resources.

---

## 7. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab07-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Vpc.VpcId' \
  --output text \
  --region "$AWS_REGION")
```

Enable DNS:

```bash
aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-support \
  --region "$AWS_REGION"

aws ec2 modify-vpc-attribute \
  --vpc-id "$VPC_ID" \
  --enable-dns-hostnames \
  --region "$AWS_REGION"
```

### Step 2 — Create Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab07-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab07-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab07-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Create Public Route Table

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab07-public-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Associate Subnets

```bash
export RT_ASSOC_A=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_A_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")

export RT_ASSOC_B=$(aws ec2 associate-route-table \
  --route-table-id "$RT_ID" \
  --subnet-id "$SUBNET_B_ID" \
  --query AssociationId \
  --output text \
  --region "$AWS_REGION")
```

Verify routes:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.166.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 8. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab07-alb-sg \
  --description "Lab07 ALB security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab07-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 80 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 2 — Create Backend Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab07-ec2-sg \
  --description "Lab07 backend security group" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab07-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Verify:

```bash
aws ec2 describe-security-groups \
  --group-ids "$ALB_SG_ID" "$EC2_SG_ID" \
  --query 'SecurityGroups[].{Name:GroupName,Inbound:IpPermissions}' \
  --output json \
  --region "$AWS_REGION"
```

---

## 9. Configure IAM for Systems Manager

### Step 1 — Create EC2 Trust Policy

Create `ec2-trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

### Step 2 — Create IAM Role

Check whether the role and profile already exist before creation.

```bash
aws iam get-role --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

For new resources, `NoSuchEntity` is expected.

```bash
aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://ec2-trust-policy.json \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam attach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam create-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --tags Key=Project,Value="$PROJECT_TAG"

aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"
```

Allow IAM changes to propagate before EC2 launch.

---

## 10. Create the Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab07

cat > /opt/lab07/app.py <<'PY'
#!/usr/bin/env python3

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class Handler(BaseHTTPRequestHandler):

    def do_GET(self):

        if self.path == "/health":
            status = 200
            body = b"OK\n"

        elif self.path == "/":
            status = 200
            body = b"AWS ELB Lab 07 - Home Page\n"

        elif self.path == "/app":
            status = 200
            body = b"AWS ELB Lab 07 - Application Working\n"

        else:
            status = 404
            body = b"Not Found\n"

        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = ThreadingHTTPServer(
        ("0.0.0.0", 8080),
        Handler
    )

    server.serve_forever()
PY

cat > /etc/systemd/system/lab07-web.service <<'UNIT'
[Unit]
Description=Lab 07 ALB Listener Rule Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/lab07/app.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab07-web.service
```

### Application Endpoints

| Endpoint | Expected Response |
|---|---|
| `/` | HTTP 200 |
| `/app` | HTTP 200 |
| `/health` | HTTP 200 |
| Unknown path | HTTP 404 |

The backend application remains unchanged during fault injection. The incident is caused entirely by the ALB listener configuration.

---

## 11. Launch EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Check Existing Instances

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}' \
  --output table \
  --region "$AWS_REGION"
```

### Step 3 — Launch EC2

```bash
export INSTANCE_ID=$(aws ec2 run-instances \
  --image-id "$AMI_ID" \
  --instance-type t3.micro \
  --iam-instance-profile "Name=$PROFILE_NAME" \
  --network-interfaces \
    "DeviceIndex=0,SubnetId=$SUBNET_A_ID,Groups=$EC2_SG_ID,AssociatePublicIpAddress=true" \
  --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
  --user-data file://backend-user-data.sh \
  --count 1 \
  --tag-specifications \
    "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab07-backend},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 4 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 5 — Connect with Systems Manager

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once the instance reports `Online`:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 6 — Verify Application

Inside EC2:

```bash
sudo systemctl is-active lab07-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i http://127.0.0.1:8080/
curl --noproxy '*' -i http://127.0.0.1:8080/app
curl --noproxy '*' -i http://127.0.0.1:8080/health
```

Expected: HTTP 200 for every endpoint.

Exit Session Manager.

---

## 12. Create Target Groups

### Step 1 — Create Correct Target Group

```bash
export APP_TG_ARN=$(aws elbv2 create-target-group \
  --name "$APP_TG_NAME" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path "/health" \
  --health-check-interval-seconds 15 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 2 \
  --matcher HttpCode=200 \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Register EC2 Target

```bash
aws elbv2 register-targets \
  --target-group-arn "$APP_TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 3 — Create Incorrect Target Group

```bash
export WRONG_TG_ARN=$(aws elbv2 create-target-group \
  --name "$WRONG_TG_NAME" \
  --protocol HTTP \
  --port 8080 \
  --vpc-id "$VPC_ID" \
  --target-type instance \
  --health-check-protocol HTTP \
  --health-check-port traffic-port \
  --health-check-path "/health" \
  --matcher HttpCode=200 \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'TargetGroups[0].TargetGroupArn' \
  --output text \
  --region "$AWS_REGION")
```

Do not register any target in the wrong target group.

### Step 4 — Verify the Empty Group

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$WRONG_TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
{
  "TargetHealthDescriptions": []
}
```

---

## 13. Create ALB and Listener

### Step 1 — Create ALB

```bash
export ALB_ARN=$(aws elbv2 create-load-balancer \
  --name "$ALB_NAME" \
  --type application \
  --scheme internet-facing \
  --ip-address-type ipv4 \
  --subnets "$SUBNET_A_ID" "$SUBNET_B_ID" \
  --security-groups "$ALB_SG_ID" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query 'LoadBalancers[0].LoadBalancerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Wait for ALB

```bash
aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Create Listener

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTP \
  --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$APP_TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION"
)
```

### Step 4 — Retrieve ALB DNS Name

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

echo "$ALB_DNS"
```

---

## 14. Establish Healthy Baseline

### Step 1 — Verify Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$APP_TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 describe-target-health \
  --target-group-arn "$APP_TG_ARN" \
  --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Step 2 — Test the Home Page

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 3 — Test Application Route

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/app"
```

Expected: HTTP 200.

### Baseline Summary

| Check | Result |
|---|---|
| ALB | Active |
| EC2 | Running |
| Application Target Group | Healthy |
| Wrong Target Group | Empty |
| Default Rule | Correct TG |
| `/` | HTTP 200 |
| `/app` | HTTP 200 |

---

## 15. Reproduce Listener Rule Misconfiguration

### Step 1 — Create Incorrect Listener Rule

```bash
export RULE_ARN=$(aws elbv2 create-rule \
  --listener-arn "$LISTENER_ARN" \
  --priority 10 \
  --conditions "Field=path-pattern,Values=/app" \
  --actions "Type=forward,TargetGroupArn=$WRONG_TG_ARN" \
  --query 'Rules[0].RuleArn' \
  --output text \
  --region "$AWS_REGION")

echo "$RULE_ARN"
```

This is the intentional fault injection.

The listener rule matches `/app` and forwards the request to the empty target group.

### Step 2 — Inspect Listener Rules

```bash
aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,Conditions:Conditions,Actions:Actions,Default:IsDefault}' \
  --output json \
  --region "$AWS_REGION"
```

Expected configuration:

```text
Priority 10:
    Path: /app
    Forward: Wrong Target Group

Default Rule:
    Forward: Correct Application Target Group
```

### Step 3 — Test Home Page

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/"
```

Expected: HTTP 200.

### Step 4 — Test Application Route

```bash
curl --noproxy '*' -i \
  "http://${ALB_DNS}/app"
```

Expected after the rule propagates:

```http
HTTP/1.1 503 Service Unavailable
Server: awselb/2.0
```

### Step 5 — Compare Paths

```bash
for path in / /app /health; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "$path → HTTP %{http_code}\n" \
    --connect-timeout 5 \
    --max-time 15 \
    "http://${ALB_DNS}${path}"
done
```

Expected:

```text
/ → HTTP 200
/app → HTTP 503
/health → HTTP 200
```

### Step 6 — Verify Target Groups

Correct target group:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$APP_TG_ARN" \
  --region "$AWS_REGION"
```

Expected: healthy target.

Wrong target group:

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$WRONG_TG_ARN" \
  --region "$AWS_REGION"
```

Expected: empty target group.

### Failure Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Backend EC2 | Running |
| Application Target Group | Healthy |
| Wrong Target Group | Empty |
| Default Rule | Correct |
| Priority 10 Rule | Incorrect |
| `/` | 200 |
| `/app` | 503 |
| Root Cause | Incorrect listener forwarding action |

---

## 16. Troubleshooting Investigation

### Check 1 — Listener Rules

```bash
aws elbv2 describe-rules \
  --listener-arn "$LISTENER_ARN" \
  --query 'Rules[].{Priority:Priority,RuleArn:RuleArn,IsDefault:IsDefault}' \
  --output table \
  --region "$AWS_REGION"
```

Finding: priority 10 rule exists.

### Check 2 — Faulty Rule Action

```bash
aws elbv2 describe-rules \
  --rule-arns "$RULE_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: `/app` forwards to the wrong target group ARN.

### Check 3 — Compare Target Group ARNs

```bash
echo "Correct target group: $APP_TG_ARN"

echo "Wrong target group: $WRONG_TG_ARN"
```

The ARN in the listener rule matches the wrong target group.

### Check 4 — Inspect Default Action

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,DefaultActions:DefaultActions}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the default action forwards to the correct group.

### Check 5 — Verify Backend Application

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab07-web.service

curl --noproxy '*' -i \
  http://127.0.0.1:8080/app
```

Expected: active and HTTP 200.

Exit Session Manager.

### Check 6 — Inspect CloudWatch 503 Errors

Prepare the ALB dimension:

```bash
export ALB_DIMENSION="${ALB_ARN#*loadbalancer/}"
```

Generate sample errors:

```bash
for i in {1..10}; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "Request $i: HTTP %{http_code}\n" \
    "http://${ALB_DNS}/app"
done
```

Query CloudWatch:

```bash
aws cloudwatch get-metric-statistics \
  --namespace AWS/ApplicationELB \
  --metric-name HTTPCode_ELB_503_Count \
  --dimensions "Name=LoadBalancer,Value=$ALB_DIMENSION" \
  --statistics Sum \
  --period 60 \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --region "$AWS_REGION"
```

Expected after metric publication: nonzero datapoints for ALB-generated HTTP 503 errors.

CloudWatch data can be delayed.

### Investigation Summary

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | HTTP 80 |
| Rule Priority | 10 |
| Rule Condition | `/app` |
| Rule Action | Wrong Target Group |
| Correct Target Group | Healthy |
| Wrong Target Group | Empty |
| EC2 | Running |
| Direct `/app` Response | HTTP 200 |
| ALB `/app` Response | HTTP 503 |
| Root Cause | Incorrect forwarding rule |

---

## 17. Root Cause Analysis

### Root Cause

A path-based ALB listener rule matched `/app` requests and forwarded them to the wrong target group.

The wrong target group contained zero registered targets.

As a result, the ALB could not forward requests to an application backend and generated HTTP 503.

### Technical Explanation

The ALB listener used a default action that forwarded requests to the healthy application target group.

However, an additional rule with priority 10 matched `/app`.

Because listener rules are evaluated in ascending priority order, the matching priority 10 rule was selected before the default action.

The selected target group had no registered targets.

Therefore, only the affected application path returned HTTP 503.

### Root Cause Flow

```text
Client Requests /app
         |
         v
ALB HTTP Listener
         |
         v
Priority 10 Rule Matches
         |
         v
Forward to Wrong Target Group
         |
         v
Registered Targets: 0
         |
         v
ALB Generates HTTP 503
```

### Why Did the Home Page Work?

The `/` path did not match the priority 10 rule.

Therefore, the ALB used the default action and forwarded the request to the healthy backend.

### Five Whys

1. **Why did `/app` return HTTP 503?** The matching rule forwarded to an empty target group.
2. **Why was the wrong target group selected?** The priority 10 rule contained the wrong target group ARN.
3. **Why wasn't the correct default rule used?** The path-specific rule matched first.
4. **Why did only `/app` fail?** The incorrect rule matched only that path.
5. **How can the issue be prevented?** Validate listener conditions, rule priorities, and forwarding actions during deployments.

---

## 18. Remediation

### Step 1 — Correct Listener Rule

```bash
aws elbv2 modify-rule \
  --rule-arn "$RULE_ARN" \
  --actions "Type=forward,TargetGroupArn=$APP_TG_ARN" \
  --region "$AWS_REGION"
```

This changes the `/app` forwarding destination to the healthy application target group.

### Step 2 — Verify Rule Configuration

```bash
aws elbv2 describe-rules \
  --rule-arns "$RULE_ARN" \
  --query 'Rules[].{Priority:Priority,Conditions:Conditions,Actions:Actions}' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```text
Priority: 10
Path: /app
Forward: Correct Application Target Group
```

### Step 3 — Verify Application Endpoint

```bash
curl --noproxy '*' -i \
  --connect-timeout 5 \
  --max-time 15 \
  "http://${ALB_DNS}/app"
```

Expected: HTTP 200.

### Step 4 — Verify All Paths

```bash
for path in / /app /health; do
  curl --noproxy '*' -sS \
    -o /dev/null \
    -w "$path → HTTP %{http_code}\n" \
    --connect-timeout 5 \
    --max-time 15 \
    "http://${ALB_DNS}${path}"
done
```

Expected:

```text
/ → HTTP 200
/app → HTTP 200
/health → HTTP 200
```

### Step 5 — Verify Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$APP_TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: healthy.

### Verification Matrix

| Check | Baseline | During Fault | After Fix |
|---|---|---|---|
| ALB | Active | Active | Active |
| EC2 | Running | Running | Running |
| Correct TG | Healthy | Healthy | Healthy |
| Wrong TG | Empty | Empty | Empty |
| `/app` Rule | Absent | Wrong TG | Correct TG |
| `/` Response | 200 | 200 | 200 |
| `/app` Response | 200 | 503 | 200 |
| Incident | None | Active | Resolved |

### Success Criteria

- ALB and EC2 deployed successfully.
- Healthy target group established.
- Empty target group created.
- Faulty `/app` listener rule created.
- HTTP 503 reproduced.
- Listener rule mismatch identified.
- Listener rule corrected.
- HTTP 200 restored.
- Temporary resources removed.

---

## 19. Production Best Practices

### ALB Listener Troubleshooting Checklist

1. Verify ALB status.
2. Inspect listener port and protocol.
3. List listener rules.
4. Check rule priority.
5. Review path and host conditions.
6. Identify matching rules.
7. Inspect forwarding actions.
8. Compare target group ARNs.
9. Check registered target counts.
10. Verify target health.
11. Test backend application directly.
12. Review ALB error metrics.
13. Correct the forwarding rule.
14. Test affected application routes.

### Common Listener Rule Problems

| Problem | Possible Effect | Remediation |
|---|---|---|
| Wrong target group | HTTP 503 or incorrect backend | Correct target group ARN |
| Wrong rule priority | Unexpected routing | Correct priorities |
| Incorrect path pattern | Requests match wrong rule | Fix path condition |
| Incorrect hostname rule | Wrong application selected | Correct host condition |
| Missing rule | Default action receives requests | Create intended rule |
| Wrong fixed-response action | Unexpected HTTP status | Correct listener action |
| Redirect misconfiguration | Wrong redirects or loops | Fix redirect settings |

### Prevention

- Manage ALB listeners with Terraform or CloudFormation.
- Review listener rules through pull requests.
- Validate target group ARNs.
- Document listener rule priorities.
- Test every critical application endpoint.
- Monitor ALB HTTP errors.
- Monitor target group health.
- Avoid unnecessary overlapping path conditions.
- Use controlled deployments.
- Maintain separate staging and production environments.

### Security Considerations

- Restrict backend access to the ALB.
- Use HTTPS for production applications.
- Apply least-privilege IAM permissions.
- Review listener changes through CloudTrail.
- Protect backend applications from direct public access.
- Remove unused listener rules and target groups.

---

## 20. Cleanup

**Warning:** Verify AWS account identity, resource IDs, and ownership tags before deleting resources.

Only delete resources belonging to `ELB-Troubleshooting-Lab07`.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[].Instances[].{ID:InstanceId,Tags:Tags}' \
  --output json \
  --region "$AWS_REGION"

aws elbv2 describe-tags \
  --resource-arns "$ALB_ARN" "$APP_TG_ARN" "$WRONG_TG_ARN" \
  --region "$AWS_REGION"
```

### Step 2 — Delete Custom Listener Rule

```bash
aws elbv2 delete-rule \
  --rule-arn "$RULE_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Delete Listener

```bash
aws elbv2 delete-listener \
  --listener-arn "$LISTENER_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Delete ALB

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Delete Both Target Groups

Deregister the application target:

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$APP_TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

Delete target groups:

```bash
aws elbv2 delete-target-group \
  --target-group-arn "$APP_TG_ARN" \
  --region "$AWS_REGION"

aws elbv2 delete-target-group \
  --target-group-arn "$WRONG_TG_ARN" \
  --region "$AWS_REGION"
```

### Step 6 — Verify EBS Root Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Remove Security Group Reference

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Check remaining network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

Continue after the lab ENIs have been deleted.

### Step 9 — Delete Security Groups

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 10 — Delete IAM Resources

Verify the IAM role belongs to this lab and is not used by other instances.

```bash
aws iam list-role-tags \
  --role-name "$ROLE_NAME"

aws iam get-instance-profile \
  --instance-profile-name "$PROFILE_NAME"
```

Delete:

```bash
aws iam detach-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore

aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROFILE_NAME" \
  --role-name "$ROLE_NAME"

aws iam delete-instance-profile \
  --instance-profile-name "$PROFILE_NAME"

aws iam delete-role \
  --role-name "$ROLE_NAME"
```

### Step 11 — Delete Route Table and Associations

```bash
aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_A" \
  --region "$AWS_REGION"

aws ec2 disassociate-route-table \
  --association-id "$RT_ASSOC_B" \
  --region "$AWS_REGION"

aws ec2 delete-route-table \
  --route-table-id "$RT_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Subnets

```bash
aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 13 — Delete Internet Gateway

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

### Step 14 — Delete VPC

```bash
aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 15 — Verify Cleanup

```bash
aws ec2 describe-instances \
  --filters \
    "Name=tag:Project,Values=$PROJECT_TAG" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].InstanceId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Verify ALB removal:

```bash
aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

Expected: `LoadBalancerNotFound`.

Also verify both target groups, EBS root volume, IAM resources, and dedicated VPC are removed.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| Custom Listener Rule | Deleted |
| ALB Listener | Deleted |
| ALB | Deleted |
| Application Target Group | Deleted |
| Wrong Target Group | Deleted |
| EC2 | Terminated |
| EBS Root Volume | Deleted |
| Security Groups | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Custom Route Table | Deleted |
| Both Subnets | Deleted |
| Internet Gateway | Deleted |
| Lab VPC | Deleted |
| Default VPC | Unchanged |

---

## 21. Interview Questions and Answers

### Q1. What is an ALB listener rule?

A listener rule determines how an ALB handles incoming requests based on conditions such as URL paths and hostnames.

### Q2. How are listener rules evaluated?

Nondefault rules are evaluated in ascending numerical priority order. The default rule is evaluated last.

### Q3. What caused HTTP 503 in this lab?

A priority 10 listener rule forwarded `/app` requests to an empty target group.

### Q4. Why did the home page work while `/app` failed?

The home page used the correct default action, while `/app` matched the incorrect custom rule.

### Q5. Can an ALB have a healthy target group while users receive HTTP 503?

Yes. A matching listener rule may forward requests to a different target group containing no registered targets.

### Q6. What command displays listener rules?

`aws elbv2 describe-rules`.

### Q7. How can you modify a listener rule?

Use `aws elbv2 modify-rule` with the correct rule ARN and forwarding action.

### Q8. What happens when no custom listener rule matches?

The ALB executes the default rule.

### Q9. What is a target group ARN?

It is the Amazon Resource Name uniquely identifying a target group.

### Q10. Which CloudWatch metric tracks ALB-generated HTTP 503?

`HTTPCode_ELB_503_Count`.

### Q11. How can you prevent incorrect listener routing?

Use infrastructure as code, review rule conditions and priorities, validate target group ARNs, and test application paths after deployments.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an EC2 backend and two target groups.

The correct target group contained a healthy EC2 instance, while the second group remained empty.

After establishing a healthy baseline, I intentionally created a priority 10 listener rule that forwarded `/app` requests to the empty target group.

This caused HTTP 503 for `/app`, while the home page continued returning HTTP 200.

I inspected listener rule priorities, forwarding actions, target group ARNs, backend health, and CloudWatch metrics.

After correcting the listener rule to forward to the healthy target group, I verified that all application routes returned HTTP 200.

---

## 22. Repository Structure

```text
07-listener-rule-misconfiguration/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete ALB listener rule troubleshooting documentation |
| `ec2-trust-policy.json` | IAM trust policy for Systems Manager access |
| `backend-user-data.sh` | Python application deployed automatically on EC2 |

Do not commit AWS credentials, private keys, or sensitive data.

---

## 23. Lessons Learned

This lab demonstrates that an Application Load Balancer can return HTTP 503 for a specific application endpoint even when its backend application and primary target group remain healthy.

The incident was caused by a listener rule forwarding `/app` to an empty target group.

The default forwarding rule was configured correctly, which allowed other application paths to continue working.

The most important troubleshooting step was examining the matching listener rule, its priority, and its forwarding target group ARN.

Correcting the rule restored application availability without changing the EC2 instance or backend service.

**Key Lesson:** When only certain application paths fail behind an ALB, inspect listener rule conditions, priorities, and forwarding actions before assuming the backend application is unhealthy.

---

## 24. Skills Demonstrated

- AWS Application Load Balancer
- Listener rule troubleshooting
- Path-based routing
- Listener rule priorities
- Target group forwarding
- HTTP 503 investigation
- AWS CLI v2
- EC2 application troubleshooting
- Linux systemd
- Systems Manager
- CloudWatch metrics
- VPC networking
- Security group configuration
- Root cause analysis
- Fault injection
- Remediation and verification
- AWS resource cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-007 |
| Problem | ALB listener rule misconfiguration |
| Root Cause | `/app` forwarded to empty target group |
| EC2 | Running |
| ALB | Active |
| Correct Target Group | Healthy |
| Wrong Target Group | Empty |
| Rule Priority | 10 |
| HTTP Response During Failure | 503 |
| Remediation | Correct forwarding action |
| Final `/app` Response | 200 |
| Final `/` Response | 200 |
| Cleanup | Temporary resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** ALB listener rules determine where requests are forwarded. An incorrect high-priority rule can cause a partial application outage even when the backend and default listener configuration are healthy.
