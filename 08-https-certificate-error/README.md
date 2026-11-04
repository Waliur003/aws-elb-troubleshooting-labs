# Lab 08 — ALB HTTPS Certificate Error

## Overview

This lab demonstrates how to troubleshoot an HTTPS certificate error on an AWS Application Load Balancer (ALB).

We deploy an internet-facing ALB with an HTTPS listener on port 443 and an Amazon EC2 backend running a Python HTTP server on port 8080.

We create a temporary private Certificate Authority (CA) and two TLS certificates:

- A correct certificate for `app.lab08.example.com`.
- An incorrect certificate for `wrong.lab08.example.com`.

Both certificates are imported into AWS Certificate Manager (ACM).

Initially, the ALB uses the correct certificate, and HTTPS requests succeed with certificate validation enabled.

We intentionally replace the listener's default certificate with the incorrect certificate. The client then rejects the TLS connection because the certificate's Subject Alternative Name (SAN) does not match the requested hostname.

We investigate the listener configuration, ACM certificates, certificate chain, hostname validation, and backend target health.

After identifying the incorrect certificate, we restore the correct certificate and verify that HTTPS works again.

**Troubleshooting workflow:**

Provision → Healthy Baseline → Fault Injection → Investigation → Root Cause Analysis → Remediation → Verification → Cleanup

---

## 1. Lab Information

| Item | Configuration |
|---|---|
| Incident ID | INC-ELB-008 |
| Difficulty | Intermediate |
| AWS Region | `us-east-1` |
| AWS Services | ALB, ACM, EC2, VPC, IAM, Systems Manager |
| ALB Type | Application Load Balancer |
| ALB Scheme | Internet-facing |
| Listener | HTTPS 443 |
| Backend Target Group | HTTP 8080 |
| EC2 | Amazon Linux 2023 |
| Instance Type | `t3.micro` |
| Application | Python HTTP Server |
| Health Check | `/health` |
| Requested Hostname | `app.lab08.example.com` |
| Incorrect Certificate | `wrong.lab08.example.com` |
| Certificate Provider | Temporary private test CA |
| Certificate Storage | AWS Certificate Manager |
| Fault Injection | Replace listener certificate |
| Expected Error | TLS hostname verification failure |
| Root Cause | Incorrect certificate SAN |
| Remediation | Restore correct ACM certificate |
| Final Verification | HTTPS 200 with certificate verification enabled |

---

## 2. Production Incident Scenario

### Incident Description

A company hosts its web application behind an AWS Application Load Balancer.

The ALB terminates HTTPS connections on port 443 and forwards requests to an EC2 backend.

The HTTPS listener is configured with a TLS certificate stored in AWS Certificate Manager.

During a certificate rotation or infrastructure deployment, an engineer accidentally attaches a certificate for the wrong domain.

The ALB continues operating, and the registered EC2 target remains healthy.

However, users receive certificate validation errors when accessing the application.

### Incident Symptoms

- ALB remains active.
- HTTPS listener remains configured on port 443.
- EC2 instance remains running.
- Backend application responds normally.
- Target group health checks succeed.
- ACM certificate status is `ISSUED`.
- The presented certificate does not match the requested hostname.
- HTTPS client validation fails.
- curl reports a certificate hostname mismatch.

### Business Impact

- Customers cannot establish trusted HTTPS connections.
- Browser users see certificate warnings or connection failures.
- API clients may reject requests.
- Application availability is affected even though EC2 is healthy.
- Monitoring limited to backend health checks may fail to detect the problem.

### Incident Objective

Determine why HTTPS fails despite a healthy backend, identify the incorrect certificate, and restore valid HTTPS connections without disabling certificate verification.

---

## 3. AWS Architecture

### Healthy Architecture

```text
                    HTTPS Client
               app.lab08.example.com
                          |
                          | HTTPS 443
                          v
             +--------------------------+
             | Application Load         |
             | Balancer                 |
             | HTTPS Listener: 443      |
             +------------+-------------+
                          |
                          v
             +--------------------------+
             | ACM TLS Certificate      |
             | SAN:                     |
             | app.lab08.example.com    |
             +------------+-------------+
                          |
                   TLS Verified
                          |
                          v
             +--------------------------+
             | Target Group             |
             | HTTP Port: 8080          |
             +------------+-------------+
                          |
                          v
             +--------------------------+
             | EC2 Python HTTP Server   |
             | Port: 8080               |
             | Health: Healthy          |
             +------------+-------------+
                          |
                          v
                     HTTP 200 OK
```

### Broken Architecture

```text
                    HTTPS Client
               app.lab08.example.com
                          |
                          v
                 ALB HTTPS Listener
                          |
                          v
                  Wrong Certificate
                          |
                          v
              wrong.lab08.example.com
                          |
                          v
               Hostname Verification
                          |
                          X
                    TLS Rejected


              EC2 Backend Remains Healthy
```

### Network Configuration

| Resource | Configuration |
|---|---|
| VPC | `10.167.0.0/16` |
| Subnet A | `10.167.1.0/24` |
| Subnet B | `10.167.2.0/24` |
| Internet Gateway | Attached |
| ALB Security Group | TCP 443 from internet |
| Backend Security Group | TCP 8080 from ALB SG |
| HTTPS Listener | Port 443 |
| Target Group | HTTP 8080 |
| Health Check | `/health` |

TLS terminates at the ALB. The backend uses HTTP inside the lab VPC.

Production architectures may require HTTPS encryption between the ALB and backend as well.

---

## 4. Understanding TLS Certificate Validation

HTTPS uses Transport Layer Security (TLS) to protect communication between a client and a server.

When connecting to an HTTPS website, the client validates several certificate properties.

### Certificate Validation

| Check | Purpose |
|---|---|
| Certificate Chain | Verifies the certificate was signed by a trusted CA |
| Validity Period | Confirms the certificate is not expired or not yet valid |
| Hostname | Confirms the certificate covers the requested domain |
| SAN | Identifies the DNS names or IP addresses covered by the certificate |
| Certificate Usage | Confirms the certificate is suitable for server authentication |

### What Is a Subject Alternative Name?

The Subject Alternative Name (SAN) identifies hostnames covered by a TLS certificate.

Example:

```text
DNS:app.lab08.example.com
```

A client connecting to that hostname can accept the certificate if the other certificate validation checks also pass.

However, a certificate containing only:

```text
DNS:wrong.lab08.example.com
```

does not match:

```text
app.lab08.example.com
```

The client rejects the certificate.

### Certificate Chain vs. Hostname Validation

These are separate security checks.

A certificate may have:

```text
Certificate Signature: Valid
CA Chain: Trusted
Certificate Expiration: Valid
Hostname: Incorrect
```

The HTTPS request must still fail because the hostname does not match.

### What Is SNI?

Server Name Indication (SNI) allows an HTTPS client to indicate the hostname it wants during TLS negotiation.

An ALB can use SNI to select an appropriate certificate from the HTTPS listener's certificate list.

If the wrong certificate is configured or selected, TLS hostname verification can fail.

### Important Distinction

This lab does **not** reproduce an ALB-generated HTTP 502, 503, or 504.

The client rejects the TLS certificate before receiving a valid HTTP application response.

---

## 5. Prerequisites and Safety

### Requirements

- AWS account
- AWS CLI v2
- Ubuntu WSL2
- Bash
- OpenSSL
- curl
- EC2 permissions
- VPC permissions
- ELBv2 permissions
- ACM permissions
- IAM permissions
- Systems Manager access
- Git and GitHub

### Security Requirements

- Use a disposable lab environment.
- Never use these test certificates in production.
- Do not upload private keys to GitHub.
- Never commit the test CA private key.
- Use unique AWS resource names.
- Verify resource ownership before cleanup.
- Remove all temporary certificates and keys after testing.

### Test Hostnames

We use:

```text
app.lab08.example.com
wrong.lab08.example.com
```

These are documentation-only hostnames.

No public DNS records are created.

The `curl --connect-to` option connects to the actual ALB DNS name while retaining the requested test hostname for HTTPS verification.

### AWS Costs

Potential charges include:

- Application Load Balancer
- Load Balancer Capacity Units
- EC2 instance
- EBS storage
- Public IPv4 address
- Applicable network traffic

The imported certificates are temporary lab materials.

---

## 6. Prepare the Environment

### Step 1 — Configure Variables

```bash
export AWS_REGION="us-east-1"
export PROJECT_TAG="ELB-Troubleshooting-Lab08"

export VPC_CIDR="10.167.0.0/16"
export SUBNET_A_CIDR="10.167.1.0/24"
export SUBNET_B_CIDR="10.167.2.0/24"

export ALB_NAME="cloud-elb-lab08-alb"
export TG_NAME="cloud-elb-lab08-tg"

export ROLE_NAME="cloud-elb-lab08-ssm-role"
export PROFILE_NAME="cloud-elb-lab08-ssm-profile"

export TEST_HOST="app.lab08.example.com"
export WRONG_HOST="wrong.lab08.example.com"
```

### Step 2 — Verify AWS and Local Tools

```bash
aws sts get-caller-identity
aws --version
openssl version
curl --version
```

### Step 3 — Select Two Availability Zones

```bash
aws ec2 describe-instance-type-offerings \
  --location-type availability-zone \
  --filters "Name=instance-type,Values=t3.micro" \
  --query 'InstanceTypeOfferings[].Location' \
  --output table \
  --region "$AWS_REGION"
```

Select two supported Availability Zones:

```bash
export AZ_A="us-east-1a"
export AZ_B="us-east-1b"
```

### Step 4 — Check Existing Resources

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output table \
  --region "$AWS_REGION"
```

```bash
aws elbv2 describe-load-balancers \
  --names "$ALB_NAME" \
  --region "$AWS_REGION"
```

A `LoadBalancerNotFound` error is expected when the ALB has not yet been created.

Avoid provisioning duplicate infrastructure.

---

## 7. Generate Temporary TLS Certificates

### Step 1 — Create a Secure Temporary Directory

```bash
umask 077

export CERT_DIR=$(mktemp -d /tmp/lab08-certs.XXXXXX)

echo "$CERT_DIR"
```

All certificate keys and generated files are stored outside the Git repository.

### Step 2 — Create a Temporary Certificate Authority

```bash
openssl req -x509 \
  -newkey rsa:2048 \
  -nodes \
  -sha256 \
  -days 7 \
  -keyout "$CERT_DIR/ca.key" \
  -out "$CERT_DIR/ca.crt" \
  -subj "/CN=Lab08 Temporary Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign"
```

Generated files:

```text
ca.key → Private CA key
ca.crt → Public CA certificate
```

### Step 3 — Create Correct Certificate

Generate the key and certificate signing request:

```bash
openssl req -new \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$CERT_DIR/correct.key" \
  -out "$CERT_DIR/correct.csr" \
  -subj "/CN=$TEST_HOST"
```

Create the extensions:

```bash
cat > "$CERT_DIR/correct.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$TEST_HOST
EOF
```

Sign the certificate:

```bash
openssl x509 -req \
  -in "$CERT_DIR/correct.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/correct.crt" \
  -days 7 \
  -sha256 \
  -extfile "$CERT_DIR/correct.ext"
```

### Step 4 — Create Incorrect Certificate

```bash
openssl req -new \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$CERT_DIR/wrong.key" \
  -out "$CERT_DIR/wrong.csr" \
  -subj "/CN=$WRONG_HOST"
```

```bash
cat > "$CERT_DIR/wrong.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=DNS:$WRONG_HOST
EOF
```

```bash
openssl x509 -req \
  -in "$CERT_DIR/wrong.csr" \
  -CA "$CERT_DIR/ca.crt" \
  -CAkey "$CERT_DIR/ca.key" \
  -CAcreateserial \
  -out "$CERT_DIR/wrong.crt" \
  -days 7 \
  -sha256 \
  -extfile "$CERT_DIR/wrong.ext"
```

### Step 5 — Inspect Certificate SANs

Correct certificate:

```bash
openssl x509 \
  -in "$CERT_DIR/correct.crt" \
  -noout -subject -issuer -dates -ext subjectAltName
```

Expected:

```text
DNS:app.lab08.example.com
```

Incorrect certificate:

```bash
openssl x509 \
  -in "$CERT_DIR/wrong.crt" \
  -noout -subject -issuer -dates -ext subjectAltName
```

Expected:

```text
DNS:wrong.lab08.example.com
```

### Step 6 — Verify Certificate Chain

```bash
openssl verify \
  -CAfile "$CERT_DIR/ca.crt" \
  "$CERT_DIR/correct.crt" \
  "$CERT_DIR/wrong.crt"
```

Expected: `OK` for both certificates.

This confirms that both certificates are signed by our temporary CA.

It does not mean both certificates are valid for the same hostname.

---

## 8. Import Certificates into ACM

### Step 1 — Import Correct Certificate

```bash
export CORRECT_CERT_ARN=$(aws acm import-certificate \
  --certificate "fileb://$CERT_DIR/correct.crt" \
  --private-key "fileb://$CERT_DIR/correct.key" \
  --certificate-chain "fileb://$CERT_DIR/ca.crt" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query CertificateArn \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Import Incorrect Certificate

```bash
export WRONG_CERT_ARN=$(aws acm import-certificate \
  --certificate "fileb://$CERT_DIR/wrong.crt" \
  --private-key "fileb://$CERT_DIR/wrong.key" \
  --certificate-chain "fileb://$CERT_DIR/ca.crt" \
  --tags Key=Project,Value="$PROJECT_TAG" \
  --query CertificateArn \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Verify Both Certificates

```bash
aws acm describe-certificate \
  --certificate-arn "$CORRECT_CERT_ARN" \
  --query 'Certificate.{Domain:DomainName,Status:Status,Type:Type}' \
  --output json \
  --region "$AWS_REGION"
```

```bash
aws acm describe-certificate \
  --certificate-arn "$WRONG_CERT_ARN" \
  --query 'Certificate.{Domain:DomainName,Status:Status,Type:Type}' \
  --output json \
  --region "$AWS_REGION"
```

Expected status:

```text
ISSUED
```

Expected type:

```text
IMPORTED
```

---

## 9. Create VPC Networking

### Step 1 — Create VPC

```bash
export VPC_ID=$(aws ec2 create-vpc \
  --cidr-block "$VPC_CIDR" \
  --tag-specifications \
  "ResourceType=vpc,Tags=[{Key=Name,Value=cloud-elb-lab08-vpc},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Step 2 — Create Public Subnets

```bash
export SUBNET_A_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_A_CIDR" \
  --availability-zone "$AZ_A" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab08-subnet-a},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")

export SUBNET_B_ID=$(aws ec2 create-subnet \
  --vpc-id "$VPC_ID" \
  --cidr-block "$SUBNET_B_CIDR" \
  --availability-zone "$AZ_B" \
  --tag-specifications \
  "ResourceType=subnet,Tags=[{Key=Name,Value=cloud-elb-lab08-subnet-b},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Subnet.SubnetId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Create Internet Gateway

```bash
export IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications \
  "ResourceType=internet-gateway,Tags=[{Key=Name,Value=cloud-elb-lab08-igw},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'InternetGateway.InternetGatewayId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 attach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Configure Public Routing

```bash
export RT_ID=$(aws ec2 create-route-table \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=route-table,Tags=[{Key=Name,Value=cloud-elb-lab08-rt},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'RouteTable.RouteTableId' \
  --output text \
  --region "$AWS_REGION")

aws ec2 create-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0" \
  --gateway-id "$IGW_ID" \
  --region "$AWS_REGION"
```

Associate both subnets:

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

Verify:

```bash
aws ec2 describe-route-tables \
  --route-table-ids "$RT_ID" \
  --query 'RouteTables[0].Routes' \
  --output table \
  --region "$AWS_REGION"
```

Expected:

```text
10.167.0.0/16 → local
0.0.0.0/0     → Internet Gateway
```

---

## 10. Configure Security Groups

### Step 1 — Create ALB Security Group

```bash
export ALB_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab08-alb-sg \
  --description "Lab08 HTTPS ALB SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab08-alb-sg},{Key=Project,Value=$PROJECT_TAG}]" \
  --query GroupId \
  --output text \
  --region "$AWS_REGION")

aws ec2 authorize-security-group-ingress \
  --group-id "$ALB_SG_ID" \
  --protocol tcp \
  --port 443 \
  --cidr "0.0.0.0/0" \
  --region "$AWS_REGION"
```

### Step 2 — Create EC2 Security Group

```bash
export EC2_SG_ID=$(aws ec2 create-security-group \
  --group-name cloud-elb-lab08-ec2-sg \
  --description "Lab08 EC2 backend SG" \
  --vpc-id "$VPC_ID" \
  --tag-specifications \
  "ResourceType=security-group,Tags=[{Key=Name,Value=cloud-elb-lab08-ec2-sg},{Key=Project,Value=$PROJECT_TAG}]" \
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

### Security Group Summary

| Security Group | Inbound |
|---|---|
| ALB SG | TCP 443 from internet |
| EC2 SG | TCP 8080 from ALB SG |

---

## 11. Configure IAM and Systems Manager

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

Check the IAM names are unused, then create the role and instance profile:

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

Allow IAM changes to propagate before launching the instance.

---

## 12. Create the Backend Application

Create `backend-user-data.sh`:

```bash
#!/bin/bash
set -eux

mkdir -p /opt/lab08

cat > /opt/lab08/index.html <<'HTML'
AWS ELB Troubleshooting Lab 08

Application: HTTPS Certificate Troubleshooting
Backend: EC2 Python HTTP Server
Status: Healthy
HTML

cat > /opt/lab08/health <<'HEALTH'
OK
HEALTH

cat > /etc/systemd/system/lab08-web.service <<'UNIT'
[Unit]
Description=Lab 08 HTTPS ALB Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/opt/lab08
ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now lab08-web.service
```

### Application Endpoints

| Endpoint | Expected Response |
|---|---|
| `/` | HTTP 200 |
| `/health` | HTTP 200 |
| Unknown path | HTTP 404 |

---

## 13. Launch EC2

### Step 1 — Retrieve Amazon Linux 2023 AMI

```bash
export AMI_ID=$(aws ssm get-parameter \
  --name "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64" \
  --query Parameter.Value \
  --output text \
  --region "$AWS_REGION")
```

### Step 2 — Launch Instance

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
  "ResourceType=instance,Tags=[{Key=Name,Value=cloud-elb-lab08-backend},{Key=Project,Value=$PROJECT_TAG}]" \
  --query 'Instances[0].InstanceId' \
  --output text \
  --region "$AWS_REGION")
```

### Step 3 — Wait for EC2

```bash
aws ec2 wait instance-running \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-status-ok \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 4 — Verify Application

Check Systems Manager:

```bash
aws ssm describe-instance-information \
  --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
  --query 'InstanceInformationList[].{ID:InstanceId,Status:PingStatus}' \
  --output table \
  --region "$AWS_REGION"
```

Once the instance is online:

```bash
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

Inside EC2:

```bash
sudo systemctl is-active lab08-web.service

sudo ss -lntp | grep ':8080'

curl --noproxy '*' -i \
  http://127.0.0.1:8080/health
```

Expected:

```text
Service: active
Port: 8080
Health Endpoint: HTTP 200
```

Exit the session.

---

## 14. Create HTTPS ALB and Target Group

### Step 1 — Create Target Group

```bash
export TG_ARN=$(aws elbv2 create-target-group \
  --name "$TG_NAME" \
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

### Step 2 — Register EC2

```bash
aws elbv2 register-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

### Step 3 — Create ALB

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

aws elbv2 wait load-balancer-available \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Create HTTPS Listener

Configure the correct certificate first:

```bash
export LISTENER_ARN=$(aws elbv2 create-listener \
  --load-balancer-arn "$ALB_ARN" \
  --protocol HTTPS \
  --port 443 \
  --certificates "CertificateArn=$CORRECT_CERT_ARN" \
  --ssl-policy ELBSecurityPolicy-TLS13-1-2-2021-06 \
  --default-actions "Type=forward,TargetGroupArn=$TG_ARN" \
  --query 'Listeners[0].ListenerArn' \
  --output text \
  --region "$AWS_REGION")
```

### Step 5 — Retrieve ALB DNS

```bash
export ALB_DNS=$(aws elbv2 describe-load-balancers \
  --load-balancer-arns "$ALB_ARN" \
  --query 'LoadBalancers[0].DNSName' \
  --output text \
  --region "$AWS_REGION")

echo "$ALB_DNS"
```

### Step 6 — Verify Target Health

```bash
aws elbv2 wait target-in-service \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"
```

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

---

## 15. Establish Healthy HTTPS Baseline

### Step 1 — Test HTTPS With Validation

```bash
curl --noproxy '*' -v \
  --cacert "$CERT_DIR/ca.crt" \
  --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
  --connect-timeout 10 \
  --max-time 30 \
  "https://$TEST_HOST/"
```

### Understanding the Command

`--cacert` tells curl to trust our temporary test CA for this connection.

`--connect-to` tells curl to connect to the real ALB DNS name while using the test hostname for certificate validation.

`https://$TEST_HOST/` specifies the hostname that must match the certificate.

Expected:

```text
SSL certificate verify ok.
HTTP/1.1 200 OK
```

### Step 2 — Test Health Endpoint

```bash
curl --noproxy '*' -i \
  --cacert "$CERT_DIR/ca.crt" \
  --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
  "https://$TEST_HOST/health"
```

Expected: HTTP 200 with `OK`.

### Baseline Summary

| Component | Expected Result |
|---|---|
| ALB | Active |
| HTTPS Listener | Port 443 |
| Listener Certificate | Correct |
| Certificate SAN | `app.lab08.example.com` |
| Certificate Chain | Trusted using test CA |
| EC2 | Running |
| Target Health | Healthy |
| HTTPS Request | HTTP 200 |

---

## 16. Fault Injection — Incorrect HTTPS Certificate

### Step 1 — Replace Listener Certificate

```bash
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --certificates "CertificateArn=$WRONG_CERT_ARN" \
  --region "$AWS_REGION"
```

**Fault injected:** the listener now uses a certificate for the wrong hostname.

### Step 2 — Verify Listener Certificate

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Port:Port,Protocol:Protocol,Certificates:Certificates}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: the certificate ARN matches `$WRONG_CERT_ARN`.

### Step 3 — Reproduce HTTPS Failure

```bash
curl --noproxy '*' -v \
  --cacert "$CERT_DIR/ca.crt" \
  --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
  --connect-timeout 10 \
  --max-time 30 \
  "https://$TEST_HOST/"
```

Expected after the configuration propagates:

```text
curl: (60) SSL: no alternative certificate
subject name matches target hostname
```

The exact message depends on the curl and TLS library versions.

### Step 4 — Inspect Curl Exit Code

```bash
curl --noproxy '*' -sS \
  --cacert "$CERT_DIR/ca.crt" \
  --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
  -o /dev/null \
  "https://$TEST_HOST/"

echo "Curl exit code: $?"
```

Expected:

```text
Curl exit code: 60
```

### Step 5 — Verify Backend Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].{ID:Target.Id,State:TargetHealth.State}' \
  --output table \
  --region "$AWS_REGION"
```

Expected: `healthy`.

### Failure Summary

| Component | Finding |
|---|---|
| ALB | Active |
| HTTPS Listener | 443 |
| EC2 | Running |
| Application | Active |
| Target Health | Healthy |
| Requested Hostname | `app.lab08.example.com` |
| Certificate SAN | `wrong.lab08.example.com` |
| Certificate Chain | Trusted by test CA |
| Client Validation | Failed |
| Root Cause | Incorrect hostname certificate |

---

## 17. Troubleshooting Investigation

### Check 1 — Inspect Presented Certificate

```bash
openssl s_client \
  -connect "${ALB_DNS}:443" \
  -servername "$TEST_HOST" \
  -showcerts \
  </dev/null 2>/dev/null \
  | openssl x509 \
      -noout \
      -subject \
      -issuer \
      -dates \
      -ext subjectAltName
```

Expected SAN:

```text
DNS:wrong.lab08.example.com
```

Finding: the ALB presents the incorrect hostname certificate.

### Check 2 — Inspect Listener Configuration

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Compare:

```bash
echo "Correct certificate: $CORRECT_CERT_ARN"
echo "Wrong certificate: $WRONG_CERT_ARN"
```

Finding: the configured default certificate is incorrect.

### Check 3 — Inspect Wrong ACM Certificate

```bash
aws acm describe-certificate \
  --certificate-arn "$WRONG_CERT_ARN" \
  --query 'Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames,Status:Status,NotAfter:NotAfter}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: the SAN does not include the requested application hostname.

### Check 4 — Inspect Correct ACM Certificate

```bash
aws acm describe-certificate \
  --certificate-arn "$CORRECT_CERT_ARN" \
  --query 'Certificate.{Domain:DomainName,SANs:SubjectAlternativeNames,Status:Status,NotAfter:NotAfter}' \
  --output json \
  --region "$AWS_REGION"
```

Finding: this certificate contains the correct hostname.

### Check 5 — Verify Certificate Chain

```bash
openssl verify \
  -CAfile "$CERT_DIR/ca.crt" \
  "$CERT_DIR/wrong.crt"
```

Expected: `OK`.

Finding: the wrong certificate has a valid signature under the test CA.

Therefore, the failure is specifically the hostname mismatch.

### Check 6 — Inspect Listener Certificate List

```bash
aws elbv2 describe-listener-certificates \
  --listener-arn "$LISTENER_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: inspect the default and additional certificates associated with the listener.

### Check 7 — Verify Backend Status

```bash
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --output json \
  --region "$AWS_REGION"
```

Finding: the backend target remains healthy.

### Investigation Matrix

| Component | Finding |
|---|---|
| ALB | Active |
| Listener | HTTPS 443 |
| ACM Certificate | Imported and issued |
| Certificate Validity | Within valid dates |
| Certificate Chain | Valid under test CA |
| Presented SAN | Wrong hostname |
| Requested Hostname | Application hostname |
| Backend Target | Healthy |
| TLS Verification | Failed |
| Root Cause | Wrong default listener certificate |

---

## 18. Root Cause Analysis

### Root Cause

The ALB HTTPS listener was configured with a TLS certificate that did not contain the requested application hostname in its Subject Alternative Name.

### Technical Explanation

The client requested:

```text
https://app.lab08.example.com
```

The ALB presented a certificate for:

```text
wrong.lab08.example.com
```

The certificate chain was signed by our temporary test CA.

However, certificate trust alone is insufficient.

The client also validates whether the certificate covers the requested hostname.

Since the certificate's SAN did not match, the client rejected the TLS connection.

### Root Cause Flow

```text
Client Requests HTTPS
         |
         v
app.lab08.example.com
         |
         v
ALB HTTPS Listener
         |
         v
Wrong Certificate Presented
         |
         v
wrong.lab08.example.com
         |
         v
Hostname Verification
         |
         X
TLS Validation Failed
```

### Five Whys

1. **Why did HTTPS fail?** Certificate hostname verification failed.
2. **Why did hostname verification fail?** The certificate SAN did not contain the requested hostname.
3. **Why was the wrong certificate presented?** The listener was configured with the wrong ACM certificate ARN.
4. **Why did backend health remain successful?** Backend HTTP health checks are independent of client-side HTTPS certificate validation.
5. **How can the issue be prevented?** Validate certificate SANs, listener configuration, SNI selection, and real HTTPS requests during deployments.

---

## 19. Remediation and Verification

### Step 1 — Restore Correct Certificate

```bash
aws elbv2 modify-listener \
  --listener-arn "$LISTENER_ARN" \
  --certificates "CertificateArn=$CORRECT_CERT_ARN" \
  --region "$AWS_REGION"
```

### Step 2 — Verify Listener Configuration

```bash
aws elbv2 describe-listeners \
  --listener-arns "$LISTENER_ARN" \
  --query 'Listeners[].{Protocol:Protocol,Port:Port,Certificates:Certificates}' \
  --output json \
  --region "$AWS_REGION"
```

Expected: correct certificate ARN.

### Step 3 — Inspect Presented Certificate

```bash
openssl s_client \
  -connect "${ALB_DNS}:443" \
  -servername "$TEST_HOST" \
  -showcerts \
  </dev/null 2>/dev/null \
  | openssl x509 \
      -noout \
      -subject \
      -issuer \
      -ext subjectAltName
```

Expected:

```text
DNS:app.lab08.example.com
```

### Step 4 — Verify HTTPS Without Disabling Certificate Validation

```bash
curl --noproxy '*' -v \
  --cacert "$CERT_DIR/ca.crt" \
  --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
  --connect-timeout 10 \
  --max-time 30 \
  "https://$TEST_HOST/"
```

Expected:

```text
SSL certificate verify ok.
HTTP/1.1 200 OK
```

### Step 5 — Verify Multiple Requests

```bash
for i in {1..5}; do
  curl --noproxy '*' -sS \
    --cacert "$CERT_DIR/ca.crt" \
    --connect-to "$TEST_HOST:443:$ALB_DNS:443" \
    --connect-timeout 10 \
    --max-time 30 \
    -o /dev/null \
    -w "Request $i: HTTP %{http_code}\n" \
    "https://$TEST_HOST/"
done
```

Expected: HTTP 200 for all five requests.

### Important Security Note

Do not use:

```bash
curl -k
```

or:

```bash
curl --insecure
```

as the remediation.

These options disable TLS certificate validation and conceal the original security issue.

### Verification Matrix

| Check | Baseline | During Failure | After Fix |
|---|---|---|---|
| ALB | Active | Active | Active |
| EC2 | Running | Running | Running |
| Target Health | Healthy | Healthy | Healthy |
| HTTPS Listener | 443 | 443 | 443 |
| Certificate SAN | Correct | Wrong | Correct |
| Certificate Chain | Trusted by test CA | Trusted by test CA | Trusted by test CA |
| Hostname Verification | Pass | Fail | Pass |
| HTTPS Result | HTTP 200 | TLS Error | HTTP 200 |

### Success Criteria

- Two test certificates generated.
- Certificates imported into ACM.
- Healthy HTTPS baseline established.
- Wrong certificate attached to listener.
- TLS hostname mismatch reproduced.
- Presented certificate inspected using OpenSSL.
- Incorrect ACM certificate identified.
- Correct certificate restored.
- HTTPS verified without bypassing certificate validation.
- Temporary AWS and local resources removed.

---

## 20. Production Best Practices

### HTTPS Certificate Troubleshooting Checklist

1. Verify the requested hostname.
2. Inspect the ALB HTTPS listener.
3. Identify the default ACM certificate ARN.
4. List additional listener certificates.
5. Verify the certificate SAN entries.
6. Check certificate expiration.
7. Verify the certificate chain.
8. Check the client's trust configuration.
9. Inspect SNI certificate selection.
10. Test the HTTPS endpoint using curl and OpenSSL.
11. Verify backend target health separately.
12. Attach the correct certificate.
13. Confirm HTTPS works with validation enabled.

### Common TLS Certificate Problems

| Problem | Symptom | Remediation |
|---|---|---|
| Incorrect certificate hostname | Hostname mismatch | Attach correct certificate |
| Expired certificate | Expiration error | Renew or replace certificate |
| Untrusted CA | Unknown issuer | Use trusted CA or configure appropriate client trust |
| Missing intermediate certificate | Chain validation failure | Correct certificate chain |
| Incorrect SNI selection | Wrong certificate presented | Review listener certificate list |
| Incorrect certificate ARN | Unexpected listener certificate | Update HTTPS listener |
| Invalid certificate dates | Certificate not yet valid or expired | Replace with valid certificate |
| TLS policy incompatibility | TLS handshake failure | Review ALB TLS security policy |

### Prevention

- Use ACM-managed public certificates for eligible production domains.
- Automate certificate renewal where supported.
- Monitor ACM certificate expiration.
- Validate SAN entries before certificate deployment.
- Review certificate ARN changes through pull requests.
- Use Terraform or CloudFormation for listener configuration.
- Test HTTPS during deployment validation.
- Monitor TLS negotiation errors.
- Avoid disabling certificate validation.
- Maintain inventory of domain-to-certificate mappings.

### Security Considerations

- Never share certificate private keys publicly.
- Do not store private keys in Git.
- Restrict certificate management permissions.
- Use trusted production certificate authorities.
- Keep TLS security policies current.
- Monitor certificate changes through CloudTrail.
- Require valid hostname and chain verification in clients.

---

## 21. Cleanup

**Warning:** Verify that resources belong to `ELB-Troubleshooting-Lab08` before deleting anything.

### Step 1 — Verify Ownership

```bash
aws sts get-caller-identity

aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output json \
  --region "$AWS_REGION"

aws elbv2 describe-tags \
  --resource-arns "$ALB_ARN" "$TG_ARN" \
  --region "$AWS_REGION"

aws acm list-tags-for-certificate \
  --certificate-arn "$CORRECT_CERT_ARN" \
  --region "$AWS_REGION"

aws acm list-tags-for-certificate \
  --certificate-arn "$WRONG_CERT_ARN" \
  --region "$AWS_REGION"
```

### Step 2 — Delete HTTPS Listener

```bash
aws elbv2 delete-listener \
  --listener-arn "$LISTENER_ARN" \
  --region "$AWS_REGION"
```

### Step 3 — Delete ALB

```bash
aws elbv2 delete-load-balancer \
  --load-balancer-arn "$ALB_ARN" \
  --region "$AWS_REGION"

aws elbv2 wait load-balancers-deleted \
  --load-balancer-arns "$ALB_ARN" \
  --region "$AWS_REGION"
```

### Step 4 — Delete Target Group

```bash
aws elbv2 deregister-targets \
  --target-group-arn "$TG_ARN" \
  --targets "Id=$INSTANCE_ID,Port=8080" \
  --region "$AWS_REGION"

aws elbv2 delete-target-group \
  --target-group-arn "$TG_ARN" \
  --region "$AWS_REGION"
```

### Step 5 — Delete Imported ACM Certificates

```bash
aws acm delete-certificate \
  --certificate-arn "$CORRECT_CERT_ARN" \
  --region "$AWS_REGION"

aws acm delete-certificate \
  --certificate-arn "$WRONG_CERT_ARN" \
  --region "$AWS_REGION"
```

If ACM reports that a certificate is still in use, verify that the ALB listener and any certificate associations have been removed.

### Step 6 — Check Root EBS Volume

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].BlockDeviceMappings' \
  --output json \
  --region "$AWS_REGION"
```

Confirm the root volume has `DeleteOnTermination=true`.

### Step 7 — Terminate EC2

```bash
aws ec2 terminate-instances \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"

aws ec2 wait instance-terminated \
  --instance-ids "$INSTANCE_ID" \
  --region "$AWS_REGION"
```

### Step 8 — Remove Security Group Dependencies

```bash
aws ec2 revoke-security-group-ingress \
  --group-id "$EC2_SG_ID" \
  --protocol tcp \
  --port 8080 \
  --source-group "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

Check network interfaces:

```bash
aws ec2 describe-network-interfaces \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{ID:NetworkInterfaceId,Status:Status}' \
  --output table \
  --region "$AWS_REGION"
```

After the lab's network interfaces are removed:

```bash
aws ec2 delete-security-group \
  --group-id "$EC2_SG_ID" \
  --region "$AWS_REGION"

aws ec2 delete-security-group \
  --group-id "$ALB_SG_ID" \
  --region "$AWS_REGION"
```

### Step 9 — Delete IAM Resources

Verify role ownership and instance profile usage first.

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

### Step 10 — Delete Route Table and Subnets

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

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_A_ID" \
  --region "$AWS_REGION"

aws ec2 delete-subnet \
  --subnet-id "$SUBNET_B_ID" \
  --region "$AWS_REGION"
```

### Step 11 — Delete Internet Gateway and VPC

```bash
aws ec2 detach-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"

aws ec2 delete-internet-gateway \
  --internet-gateway-id "$IGW_ID" \
  --region "$AWS_REGION"

aws ec2 delete-vpc \
  --vpc-id "$VPC_ID" \
  --region "$AWS_REGION"
```

### Step 12 — Delete Local Certificate Materials

Verify the temporary directory:

```bash
printf 'Certificate directory: %s\n' "$CERT_DIR"
```

Only delete it if it matches the directory created for this lab:

```bash
case "$CERT_DIR" in
  /tmp/lab08-certs.*)
    rm -rf -- "$CERT_DIR"
    echo "Temporary certificate files removed"
    ;;
  *)
    echo "Unexpected directory. Verify manually."
    ;;
esac
```

Do not remove unrelated directories.

### Step 13 — Verify Cleanup

```bash
aws ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=$PROJECT_TAG" \
  --query 'Vpcs[].VpcId' \
  --output json \
  --region "$AWS_REGION"
```

Expected:

```json
[]
```

Also verify that the ALB, target group, both ACM certificates, EC2 instance, EBS volume, IAM resources, and associated networking resources are deleted.

### Cleanup Summary

| Resource | Expected Result |
|---|---|
| HTTPS Listener | Deleted |
| ALB | Deleted |
| Target Group | Deleted |
| Correct ACM Certificate | Deleted |
| Incorrect ACM Certificate | Deleted |
| EC2 Instance | Terminated |
| EBS Root Volume | Deleted |
| Security Groups | Deleted |
| IAM Role | Deleted |
| Instance Profile | Deleted |
| Route Table | Deleted |
| Subnets | Deleted |
| Internet Gateway | Deleted |
| VPC | Deleted |
| Temporary Private Keys | Removed |
| Default VPC | Unchanged |

---

## 22. Interview Questions and Answers

### Q1. What causes an HTTPS certificate hostname mismatch?

The server presents a certificate whose SAN does not include the hostname requested by the client.

### Q2. What caused the failure in this lab?

The ALB listener was configured with a certificate for `wrong.lab08.example.com` instead of `app.lab08.example.com`.

### Q3. Can an ALB target be healthy while HTTPS fails?

Yes. Backend health checks may succeed while client-side TLS validation fails.

### Q4. What AWS service manages certificates for ALB HTTPS listeners?

AWS Certificate Manager (ACM).

### Q5. What is the Subject Alternative Name?

SAN is a certificate extension identifying the hostnames or addresses covered by the certificate.

### Q6. What is SNI?

Server Name Indication allows an HTTPS client to specify the intended hostname during TLS negotiation.

### Q7. What AWS CLI command changes the ALB listener certificate?

`aws elbv2 modify-listener --certificates`.

### Q8. How do you inspect a remote certificate?

Use `openssl s_client` to retrieve the certificate, then `openssl x509` to inspect its properties.

### Q9. What is the difference between certificate trust and hostname verification?

Certificate trust checks the issuing CA chain. Hostname verification checks whether the certificate matches the hostname requested by the client.

### Q10. Why should you avoid `curl -k`?

It disables certificate verification and hides TLS security problems.

### Q11. What other TLS certificate errors might occur?

Expired certificates, untrusted CAs, incomplete certificate chains, incorrect SANs, and incorrect SNI certificate selection.

### Q12. How would you explain this lab in an interview?

I deployed an AWS Application Load Balancer with an HTTPS listener and an EC2 backend.

I generated two temporary TLS certificates, imported them into AWS Certificate Manager, and established successful HTTPS connectivity with the correct certificate.

I then intentionally replaced the HTTPS listener certificate with one belonging to a different hostname.

The client rejected the TLS connection because the certificate SAN did not match the requested application hostname.

I investigated the HTTPS listener, ACM certificate properties, certificate chain, and backend target health using AWS CLI, curl, and OpenSSL.

After restoring the correct certificate, I verified successful HTTPS connections with certificate validation enabled.

---

## 23. Repository Structure

```text
08-https-certificate-error/
├── README.md
├── ec2-trust-policy.json
└── backend-user-data.sh
```

### File Descriptions

| File | Purpose |
|---|---|
| `README.md` | Complete HTTPS certificate incident documentation |
| `ec2-trust-policy.json` | IAM trust policy for EC2 Systems Manager |
| `backend-user-data.sh` | Deploys the Python HTTP backend |

### Files That Must Not Be Committed

```text
*.key
*.pem
*.p12
*.pfx
```

Temporary private keys and certificates generated during this exercise should remain outside the repository.

The certificate creation commands are documented in this README so the experiment can be reproduced safely without storing private keys in Git.

---

## 24. Lessons Learned

This lab demonstrates that an AWS Application Load Balancer can have a healthy backend while HTTPS connections fail because of certificate configuration.

The incident was caused by an incorrect TLS certificate attached to the ALB listener.

Although the certificate had a valid signature under our temporary test CA, its SAN did not match the requested application hostname.

The most important troubleshooting steps were inspecting the presented certificate, checking the SAN, comparing ACM certificate ARNs, and verifying the HTTPS connection without disabling certificate validation.

Replacing the incorrect listener certificate restored successful HTTPS connectivity.

**Key Lesson:** A healthy EC2 backend does not guarantee secure HTTPS access. Always verify the certificate presented by the ALB, its trust chain, validity period, and hostname coverage.

---

## 25. Skills Demonstrated

- AWS Application Load Balancer
- HTTPS listener troubleshooting
- AWS Certificate Manager
- TLS certificate generation
- Certificate chain validation
- Subject Alternative Name inspection
- Server Name Indication
- OpenSSL
- curl certificate verification
- AWS CLI v2
- EC2 backend diagnostics
- Systems Manager
- VPC networking
- Security group configuration
- Fault injection
- Root cause analysis
- Certificate remediation
- Secure cleanup

## Final Outcome

| Item | Expected Result |
|---|---|
| Incident | INC-ELB-008 |
| Problem | HTTPS certificate hostname mismatch |
| Root Cause | Incorrect listener certificate |
| ALB | Active |
| Backend EC2 | Healthy |
| Target Group | Healthy |
| Requested Hostname | `app.lab08.example.com` |
| Incorrect SAN | `wrong.lab08.example.com` |
| TLS Validation During Fault | Failed |
| Remediation | Restore correct certificate |
| Final HTTPS Response | HTTP 200 |
| Certificate Validation | Successful |
| Cleanup | AWS and temporary local resources removed |
| Expected Incident Status | Resolved |

**Key Takeaway:** Troubleshooting HTTPS failures requires checking both certificate trust and hostname validation. A valid certificate chain cannot compensate for a certificate that belongs to the wrong hostname.
