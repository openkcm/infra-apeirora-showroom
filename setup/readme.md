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
