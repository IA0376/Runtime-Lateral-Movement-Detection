# Talos and Zarf security lab

This repository holds the deployment and experiment code for an MSc dissertation. It installs a Talos Kubernetes cluster, a set of Zarf packages (CNI, storage, PKI/secrets, GitOps and runtime-security sensors), equivalent Helm and GitOps experiment workloads, and a read-only results portal used to measure policy-aware intrusion detection.

## Deploy

One command builds every package, pushes its images to the provisioner Gitea, resets the Talos nodes and deploys the lab from scratch:

```bash
LAB_REGISTRY_PASSWORD='<provisioner gitea password>' ./deploy-all.sh
```

The provisioner Gitea password must be passed so the images can be pushed to the registry. Run `./deploy-all.sh --help` for the available options.
