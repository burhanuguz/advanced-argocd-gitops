## Demo

Quick demo on kind clusters. I had created '*.local.gd' tls certificate with a Root CA I created. In the ArgoCD values yaml file, I use the key and crt I store in Azure Key Vault. You can do the changes for your own cluster.

Script for the installation is in the git repo as well.

### ArgoCD and Ingress Installation

- The first part is to install a master cluster. NodePorts will be used by Nginx Ingress and will make 80 and 443 to be available on the host.

```bash
## Create the master cluster
cat << EOF | kind create cluster --config -
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: master
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 80
  - containerPort: 30443
    hostPort: 443
EOF
## Wait for the master Kubernetes cluster to get ready
kubectl --context "kind-master" wait --namespace kube-system --for=condition=ready pod --all --timeout=120s
```

- Next, install ingress and argocd

```bash
## Install Kubernetes Nginx Ingress
helm upgrade --install ingress-nginx ingress-nginx --kube-context "kind-master" \
    --repo https://kubernetes.github.io/ingress-nginx \
    --namespace ingress-nginx --create-namespace \
    --set controller.ingressClassResource.default=true \
    --set controller.service.type=NodePort \
    --set controller.service.nodePorts.http=30080 \
    --set controller.service.nodePorts.https=30443 \
    --set controller.extraArgs.enable-ssl-passthrough=''

## Wait for ingress to get ready
kubectl --context "kind-master" wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/mponent=controller --timeout=120s

## Install ArgoCD cluster. I use the same values YAML as the values files inside the GitHub repository
helm upgrade --install argocd argo-cd --kube-context "kind-master" \
    --repo https://argoproj.github.io/argo-helm \
    --namespace=argocd --create-namespace \
    -f argocd-values.yaml

## Wait for argocd to get ready
kubectl --context "kind-master" wait --namespace argocd --for=condition=ready pod --all --timeout=120s
```

- After that, you will be able to login into the cluster. Apply argo-app yaml that has ApplicationSet. With it, you will be able to make cluster deployments in the next section.

```bash
## Get the initial secret and then apply the argo-appy.yaml to install the Application Set to the cluster.
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl apply -f argo-app.yaml
```

- In this gif, you will find installation up to this point

![1](https://user-images.githubusercontent.com/59168275/193477170-41fc9b43-0958-4803-a9a1-dbcd669dcfa3.gif)

### Logging into the ArgoCD instance, using ArgoCD Vault Plugin, and managing ArgoCD with ArgoCD

- The second gif consists of several steps. I have used argocd-vault-plugin-helm-remote-repo and pulled the secret from my own Azure Key Vault.
  - I created a service principal in Azure, then I gave a Key Vault reader role with Azure RBAC. I have changed the Key Vault access policy to RBAC as well. Here is my Azure Key Vault Backed Yaml secret YAML as a template.

```yaml
apiVersion: v1
stringData:
  AZURE_TENANT_ID: '<base64-encoded-value>'
  AZURE_CLIENT_ID: '<base64-encoded-value>'
  AZURE_CLIENT_SECRET: '<base64-encoded-value>'
  AVP_TYPE: azurekeyvault
kind: Secret
metadata:
  name: argocd-vault-plugin-azure-credentials-in-cluster
  namespace: argocd
```

- I showed logon in this gif. First, it is insecure and also in-cluster-argocd gives an error because the secret was not applied. I applied it and refreshed the Application resource, then the automated sync worked, and made the changes.
- My ArgoCD instance started working with my own certificate defined in it, and that certificate information comes from Azure Key Vault.
- I commented on ArgoCD with TLS configuration lines. You can integrate your Vault and make use of it.
- At last, you will see ApplicationSet is degraded because it can not find cluster-1 and cluster-2. Let's create those clusters and manage them as well.

![2](https://user-images.githubusercontent.com/59168275/193478206-27b794f4-df4f-4275-9da9-9fe20117b458.gif)

### Creating cluster-1 and cluster-2 and managing them

- Create kind clusters first.

```bash
## Create other two clusters
kind create cluster --name=cluster-1
kind create cluster --name=cluster-2
```

- Then copy their kubeconfig files. We will combine master, cluster-1, and cluster-2 kubeconfig files and use them to add those clusters to ArgoCD. Unfortunately, we have to do these in the master-control-plane container because Windows WSL can not reach to clusters' control plane without reaching to container network.
  - Also, download the argocd-cli only from the ArgoCD instance itself. It always uses the latest version. New Kubernetes versions do not create service account secret tokens, but ArgoCD needs service account secret tokens. The New ArgoCD client solves it via creating the secret manually and adding annotation manually while adding the remote clusters into the main ArgoCD instance.

```bash
## Copy their kubeconfig YAML file. We also will use combine three conf, and their use is the same, we need to change the username in kubeconfig YAMLs
docker cp cluster-1-control-plane:/etc/kubernetes/admin.conf ../cluster-1-admin.conf; sed -i 's/kubernetes-admin/kubernetes-admin-1/' ../cluster-1-admin.conf
docker cp cluster-2-control-plane:/etc/kubernetes/admin.conf ../cluster-2-admin.conf; sed -i 's/kubernetes-admin/kubernetes-admin-2/' ../cluster-2-admin.conf
wget --no-check-certificate https://argocd.local.gd/download/argocd-linux-amd64 -O ../argocd-linux-amd64
```

- Next, copy the kubeconfig files and argocd-cli to master-control-plane

```bash
## Copy argocd cli and kubeconfig files to the kind-master cluster. Windows WSL2 can not communicate
## with containers. That's why it has to be dealt with inside the container.
docker cp ../cluster-1-admin.conf master-control-plane:/root/
docker cp ../cluster-2-admin.conf master-control-plane:/root/
docker cp ../argocd-linux-amd64   master-control-plane:/root/argocd
```

- Make the argocd cli as an executable

```bash
## Run commands below to login and then and other clusters to argocd to manage
docker exec -it master-control-plane chmod +x /root/argocd
```

- Login to the ArgoCD instance inside of the master-control-plane.

```bash
argoPass=$(kubectl --context kind-master -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
docker exec -it master-control-plane /root/argocd login argocd.local.gd:30443 --insecure --username=admin --password="${argoPass}"
```

- The last stage is to add those clusters with the commands below.

```bash
## Combining all three cluster in one kubeconfig and using them for each command
kindconfig='/etc/kubernetes/admin.conf:/root/cluster-1-admin.conf:/root/cluster-2-admin.conf'
docker exec -it master-control-plane bash -c "KUBECONFIG=${kindconfig} /root/argocd cluster add --name cluster-1 --insecure kubernetes-admin-1@cluster-1 --yes"
docker exec -it master-control-plane bash -c "KUBECONFIG=${kindconfig} /root/argocd cluster add --name cluster-2 --insecure kubernetes-admin-2@cluster-2 --yes"
```

- Now, you can log in to ArgoCD and refresh the Application Set object. You will see that applications will be deployed.

![3](https://user-images.githubusercontent.com/59168275/193477580-5e6e1021-7392-4ef2-941b-aa303f1e70d4.gif)
