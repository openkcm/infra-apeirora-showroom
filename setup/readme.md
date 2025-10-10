1) Create a Infra Cluster in the project with this settings:
  extensions:
    - type: shoot-cert-service
      providerConfig:
        apiVersion: service.cert.extensions.gardener.cloud/v1alpha1
        kind: CertConfig
        shootIssuers:
          enabled: true
    - type: shoot-oidc-service

  kubernetes:
    kubeAPIServer:
      serviceAccountConfig:
        issuer: https://oidc.showroominfra.kms20.shoot.canary.k8s-hana.ondemand.com

2) Run Flux Install

3) Run kubectl apply -k ./enviroments/infra/cluster/

4) Add the SOPS Secret.
if age.agekey not on you client load it from the vault and add to the root of this repo. Its part of the .gitignore one.

kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=./age.agekey

5) Check if the Test Secret get rollout and decrypt on the cluster.

6) Check if the configmap showroominfra-issuer-configmap for structed auth exist in your project. If nor apply it from the issuer-config-map.yaml file.

7) Create a worker Cluster and enable structuredAuthentication
 kubernetes:
    kubeAPIServer:
      structuredAuthentication:
        configMapName: showroominfra-issuer-configmap

8) Apply the rbac.yaml file to the worker cluster you find in rbac.yaml

9) Add or Update the cluster ca of the worker. (Need that auth can work)

10) Check if anything comes up

