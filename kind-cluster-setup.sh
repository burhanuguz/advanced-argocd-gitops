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

## Get the initial secret and then apply the argo-appy.yaml to install the Application Set to the cluster.
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
kubectl apply -f argo-app.yaml

## Create other two clusters
kind create cluster --name=cluster-1
kind create cluster --name=cluster-2

## Copy their kubeconfig YAML file. We also will use combine three conf, and their use is the same, we need to change the username in kubeconfig YAMLs
docker cp cluster-1-control-plane:/etc/kubernetes/admin.conf ../cluster-1-admin.conf; sed -i 's/kubernetes-admin/kubernetes-admin-1/' ../cluster-1-admin.conf
docker cp cluster-2-control-plane:/etc/kubernetes/admin.conf ../cluster-2-admin.conf; sed -i 's/kubernetes-admin/kubernetes-admin-2/' ../cluster-2-admin.conf
wget --no-check-certificate https://argocd.local.gd/download/argocd-linux-amd64 -O ../argocd-linux-amd64

## Copy argocd cli and kubeconfig files to kind-master cluster. Windows WSL2 can not communicate
## with containers. That's why it has to be dealt with inside the container.
docker cp ../cluster-1-admin.conf master-control-plane:/root/
docker cp ../cluster-2-admin.conf master-control-plane:/root/
docker cp ../argocd-linux-amd64   master-control-plane:/root/argocd

## Run commands below to login and then and other clusters to argocd to manage
docker exec -it master-control-plane chmod +x /root/argocd

argoPass=$(kubectl --context kind-master -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)
docker exec -it master-control-plane /root/argocd login argocd.local.gd:30443 --insecure --username=admin --password="${argoPass}"

## Combining all three cluster in one kubeconfig and using them for each command
kindconfig='/etc/kubernetes/admin.conf:/root/cluster-1-admin.conf:/root/cluster-2-admin.conf'
docker exec -it master-control-plane bash -c "KUBECONFIG=${kindconfig} /root/argocd cluster add --name cluster-1 --insecure kubernetes-admin-1@cluster-1 --yes"
docker exec -it master-control-plane bash -c "KUBECONFIG=${kindconfig} /root/argocd cluster add --name cluster-2 --insecure kubernetes-admin-2@cluster-2 --yes"