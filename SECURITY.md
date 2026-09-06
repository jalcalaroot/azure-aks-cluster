# Security Policy

This is a personal learning/reference infrastructure project (Terraform + Azure), not intended for production use. There are no supported version branches — only `main` is maintained.

## Reporting a Vulnerability

If you find a security issue — an exposed secret, a leaked credential in git history, a misconfigured resource, or a vulnerable dependency — please report it privately using [GitHub's private vulnerability reporting](../../security/advisories/new) instead of opening a public issue.

## Scope

- This repository's Terraform configuration and the Azure resources it defines
- The Kubernetes manifests in `k8s/`
- The `docker/` hello-world image definition
- Accidentally committed state files, `.tfvars`, or other secrets

Out of scope: vulnerabilities in the underlying Terraform providers, Azure services, Kubernetes itself, Let's Encrypt/ACME, or other upstream software — please report those to their respective maintainers.
