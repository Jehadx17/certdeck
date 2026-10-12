# Certified Kubernetes Application Developer (CKAD) curriculum (Kubernetes v1.37)
Source: https://github.com/cncf/curriculum (CKAD_Curriculum_v1.37.pdf)
Format: performance-based; solve tasks on live clusters from the command line (kubectl, YAML manifests, Helm, Kustomize) in 2 hours; pass 66%. Exam questions are hands-on tasks, so cards should drill imperative kubectl commands, manifest fields, and debugging steps.
Weights: 1 Application Design and Build 20%, 2 Application Deployment 20%, 3 Application Observability and Maintenance 15%, 4 Application Environment, Configuration and Security 25%, 5 Services and Networking 20%.

## Domain 1: Application Design and Build (20%)
Skills: Define, build and modify container images; Choose and use the right workload resource (Deployment, DaemonSet, CronJob, etc.); Understand multi-container Pod design patterns (e.g. sidecar, init and others); Utilize persistent and ephemeral volumes.

## Domain 2: Application Deployment (20%)
Skills: Use Kubernetes primitives to implement common deployment strategies (e.g. blue/green or canary); Understand Deployments and how to perform rolling updates; Use the Helm package manager to deploy existing packages; Kustomize.

## Domain 3: Application Observability and Maintenance (15%)
Skills: Understand API deprecations; Implement probes and health checks; Use built-in CLI tools to monitor Kubernetes applications; Utilize container logs; Debugging in Kubernetes.

## Domain 4: Application Environment, Configuration and Security (25%)
Skills: Discover and use resources that extend Kubernetes (CRD, Operators); Understand authentication, authorization and admission control; Understand requests, limits, quotas; Define resource requirements; Understand ConfigMaps; Create & consume Secrets; Understand ServiceAccounts; Understand Application Security (SecurityContexts, Capabilities, etc.).

## Domain 5: Services and Networking (20%)
Skills: Demonstrate basic understanding of NetworkPolicies; Provide and troubleshoot access to applications via services; Use Ingress rules to expose applications.
