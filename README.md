# AWS Elastic Load Balancing — Troubleshooting Labs

## Overview

This repository contains 12 hands-on AWS Elastic Load Balancing troubleshooting labs designed to simulate common production networking and application availability incidents.

The labs focus on diagnosing and fixing Application Load Balancer (ALB) and Network Load Balancer (NLB) failures using AWS CLI, Linux, networking tools, and AWS monitoring services.

Each lab follows a structured production troubleshooting process, including environment setup, fault injection, investigation, root cause analysis, remediation, verification, and cleanup.

## Objectives

- Understand AWS Application Load Balancer and Network Load Balancer architecture.
- Troubleshoot unhealthy targets and failed health checks.
- Investigate ALB HTTP 502, 503, and 504 errors.
- Diagnose listener rules and target group configuration.
- Troubleshoot HTTPS certificates and TLS configuration.
- Identify load balancer security group problems.
- Investigate target registration failures.
- Diagnose idle timeout and connection failures.
- Practice AWS CLI and Linux networking commands.
- Develop practical cloud engineering and cloud security troubleshooting skills.

## Technologies

| Technology | Purpose |
|---|---|
| AWS Application Load Balancer | Layer 7 HTTP/HTTPS traffic distribution |
| AWS Network Load Balancer | Layer 4 TCP/TLS/UDP traffic distribution |
| Amazon EC2 | Backend application servers |
| Target Groups | Register and monitor backend targets |
| ALB Listeners | Process incoming client connections |
| AWS Certificate Manager | Manage TLS certificates |
| Amazon VPC | Networking environment |
| Security Groups | Control permitted network traffic |
| CloudWatch | Monitor load balancer metrics |
| AWS CLI v2 | Manage and troubleshoot AWS infrastructure |
| Linux / Bash | Backend diagnostics and automation |
| curl / OpenSSL | HTTP and TLS troubleshooting |

## Repository Structure

```text
aws-elb-troubleshooting-labs/
│
├── README.md
│
├── 01-alb-target-unhealthy/
├── 02-alb-502-bad-gateway/
├── 03-alb-503-service-unavailable/
├── 04-alb-504-gateway-timeout/
├── 05-incorrect-target-port/
├── 06-health-check-path-failure/
├── 07-listener-rule-misconfiguration/
├── 08-https-certificate-error/
├── 09-alb-security-group-misconfiguration/
├── 10-target-registration-failure/
├── 11-idle-timeout-problem/
└── 12-nlb-connectivity-failure/
```

## Troubleshooting Labs

| Lab | Scenario | Primary Investigation |
|---|---|---|
| 01 | ALB Target Unhealthy | Target health status and health check failures |
| 02 | ALB 502 Bad Gateway | Invalid responses, connection resets, backend failures |
| 03 | ALB 503 Service Unavailable | Missing or unavailable registered targets |
| 04 | ALB 504 Gateway Timeout | Backend connection and response timeouts |
| 05 | Incorrect Target Port | Target group port and backend listener mismatch |
| 06 | Health Check Path Failure | Incorrect health check URL and response code |
| 07 | Listener Rule Misconfiguration | Listener conditions, priorities, and target group forwarding |
| 08 | HTTPS Certificate Error | ACM certificates, domain validation, and HTTPS configuration |
| 09 | ALB Security Group Misconfiguration | ALB ingress and backend communication restrictions |
| 10 | Target Registration Failure | Incorrect target registration and target group compatibility |
| 11 | Idle Timeout Problem | ALB connection idle timeout behavior |
| 12 | NLB Connectivity Failure | TCP listeners, target health, routing, and network security |

## Standard Lab Methodology

Every lab follows the same incident investigation process.

### 1. Environment Setup

Provision the required AWS infrastructure, including VPC resources, EC2 instances, load balancers, listeners, and target groups.

### 2. Healthy Baseline

Verify that application traffic and load balancer health checks work before introducing a failure, whenever the scenario permits.

### 3. Fault Injection

Intentionally introduce a specific misconfiguration or application failure inside the dedicated lab environment.

### 4. Investigation

Use AWS CLI, CloudWatch, curl, OpenSSL, and Linux diagnostics to investigate symptoms and identify the affected resources.

### 5. Root Cause Analysis

Explain why the failure occurred and identify the AWS networking or application configuration responsible.

### 6. Remediation

Apply the appropriate configuration change to restore service availability.

### 7. Verification

Repeat health checks and application connectivity tests to confirm that the issue has been resolved.

### 8. Cleanup

Remove temporary AWS resources to avoid unnecessary charges.

## Common AWS CLI Commands

### Describe Load Balancers

```bash
aws elbv2 describe-load-balancers \
  --region us-east-1
```

### Describe Target Groups

```bash
aws elbv2 describe-target-groups \
  --region us-east-1
```

### Describe Target Health

```bash
aws elbv2 describe-target-health \
  --target-group-arn TARGET_GROUP_ARN \
  --region us-east-1
```

### Describe Listeners

```bash
aws elbv2 describe-listeners \
  --load-balancer-arn LOAD_BALANCER_ARN \
  --region us-east-1
```

### Describe Listener Rules

```bash
aws elbv2 describe-rules \
  --listener-arn LISTENER_ARN \
  --region us-east-1
```

### Test Application Response

```bash
curl -v http://ALB_DNS_NAME
```

### Test HTTPS

```bash
curl -Iv https://YOUR_DOMAIN
```

## Production Troubleshooting Checklist

When diagnosing an Elastic Load Balancing issue:

1. Check load balancer state.
2. Verify listeners and listener rules.
3. Identify the intended target group.
4. Inspect registered targets.
5. Check target health and reason codes.
6. Confirm EC2 instances are running.
7. Verify the backend service is listening on the configured port.
8. Check health check protocol, port, path, and matcher.
9. Inspect ALB and target security groups.
10. Verify subnet routing and network ACLs.
11. Review relevant CloudWatch metrics.
12. Test the client request and backend response.
13. Apply remediation and verify recovery.

## Security Best Practices

- Use least-privilege IAM permissions.
- Restrict backend security group access to the load balancer where supported.
- Use HTTPS and valid TLS certificates for production applications.
- Avoid unnecessarily exposing backend services to the internet.
- Monitor unhealthy targets and HTTP 5xx errors.
- Protect sensitive application logs and credentials.
- Manage infrastructure configuration through version control.
- Remove unused load balancers and target groups.

## AWS Cost Awareness

Load balancers incur hourly and usage-related charges.

Additional costs may apply to EC2, EBS, public IPv4 addresses, CloudWatch, cross-AZ traffic, and other resources.

Every lab includes cleanup instructions.

Always verify resource deletion after completing an exercise.

## Skills Developed

- AWS Elastic Load Balancing administration
- ALB and NLB troubleshooting
- Target group health diagnostics
- HTTP 5xx incident investigation
- Listener and routing configuration
- Security group troubleshooting
- TLS and certificate troubleshooting
- Linux application diagnostics
- CloudWatch monitoring
- AWS CLI automation
- Root cause analysis
- Production incident remediation

## Purpose

This repository demonstrates practical AWS cloud engineering and cloud security troubleshooting skills through hands-on, production-inspired scenarios.

The focus is on understanding failures, diagnosing their root causes, applying reliable remediation, and documenting the results clearly.
