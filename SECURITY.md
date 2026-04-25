# Security Policy

## Scope

This policy covers the `aegis-enclave` repository: its application source, containerization configurations (`Dockerfile`, `docker-compose.yml`, WireGuard demo plumbing), its Terraform code (plan-only per ADR-0015), and its documentation (ADRs, design doc, runbooks). Out of scope: third-party dependencies (report to the originating upstream), test or demo deployments stood up by users from this template, and theoretical attacks without a working proof of concept.

## Reporting a Vulnerability

Email **pcpunkhades@gmail.com** with the subject line `Security: aegis-enclave — <short description>`. Include the following in the report:

- Affected version or commit SHA
- Reproduction steps (smallest path to trigger the issue)
- Impact assessment (what an attacker gains)
- Suggested mitigation, if known

Sensitive details can be encrypted with the maintainer's PGP key on request — ask in your initial mail and a key will be provided in reply.

## Response Timeline

- **Acknowledgement**: within 72 hours of report
- **Triage and severity assessment**: within 7 days
- **Fix development**: severity-dependent (Critical: 14 days target; High: 30 days; Medium: 90 days; Low: best-effort)
- **Public disclosure**: coordinated with the reporter, typically not before 90 days unless mutually agreed earlier

## Out of Scope

- Brute-force attacks against demo credentials
- Denial-of-service attacks (the repo is a template, not a hosted service)
- Social engineering against contributors
- Theoretical attacks without a working proof of concept
- Vulnerabilities in dependencies of dependencies (transitive) — report to the originating upstream
- Issues in test or demo environments stood up by users from this template

## Recognition

Security researchers who report responsibly will be credited in release notes unless they prefer anonymity. There is no bug-bounty program at this stage; goodwill credit only. If a report leads to a substantive architectural change, the corresponding ADR will note the reporter where appropriate.

## Capability Gates for AI Agents

This repo's migration runbook is designed for AI-agent execution under capability gates (see ADR-0012 and CLAUDE.md § 7). If a vulnerability concerns an AI agent's privilege escalation, a prompt-injection vector, or a capability-gate bypass, mark the report as **"AI agent capability bypass"** in the subject line so it routes to the architecture review path rather than the standard application-security path.

## Versioning

Security updates apply to the latest commit on `main`. The repo follows continuous-delivery semantics; there are no maintained release branches. If you operate a fork from a specific commit, you are responsible for backporting fixes to your fork.
