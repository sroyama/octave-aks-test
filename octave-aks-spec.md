# Octave AKS Cluster

## Objective 
Create an Flux delivery solution to deploy and manage Octave Web application to Azure.

## Context
- We have a local docker compose that includes all the services for Octave application. The first step is to convet the local docker compose to The AKS cluster. The compose is located at `..\octave-docker\octave-local-compose\`. 
- Another AKS cluster `..\octave-perf-aks` was created for performance testing purpose. It's fully functional, and we can reuse most of its Flux infrasture.
- The cluster is not for production. It's for development and internal review. Being easy to change and update is more important than performance.

## Requirements
- Manage the Cluster based on Flux GitOps infrastructure.
- Follow Flux's recommendation for the file strucuture like `base`, `overlays`, `infrastructure` etc.
- All the services in `octave-local-compose` should bring to this cluster except `reverse-proxy` and `octave-pixelsmart-webapi-old`.
- The `reverse-proxy` should be replaced by AKS ingress. 
- Use HAProxy to replace `ingress-nginx` in `.\octave-perf-aks`'s infrastructure for ingress control.
- The cluster should expose only these services to the Internet:
    1. octave-client
    2. octave-webapi
    3. harmony-ui-mock
    4. dotnet-harmony-api-mock
- Only authenticated users (in particular domain such as topcon.com) can access these service. We can take the same approach as `..\octave-perf-aks` by including `oauth2-proxy` in the cluster. The web app will be registered as an Azure's enterprise application. 
- All securities for the services such as user name, password, token, etc. should not be stored in the source repo. It should be given at runtime by external resource such as Azure Key-vault, or external files.