# ArgoCD [ApplicationSet](https://argocd-applicationset.readthedocs.io/en/stable/) + [Vault Plugin](https://argocd-vault-plugin.readthedocs.io/en/stable/) Advanced Use Case with Helm

TL;DR: Helm local/remote with external value deployments + Kubernetes Manifests Deployments + With/Without Vault Plugins and you can dig into one app of a cluster at any time.

In this demo, you will see a custom solution for managing clusters with Kubernetes manifests and helm packages within a mono or multi-repo while keeping your secrets in a vault that [ArgoCD Vault Plugin](https://argocd-vault-plugin.readthedocs.io/en/stable/backends/) supports as backend.

With the correct YAML manifests and helm packages, you can deploy any resource to any cloud or on-premise Kubernetes platform. In this way, you can even deploy operators, and their instances with YAML manifests.

With the plugin customizations, it is possible to easily add two external value files(one base, and one cluster-specific) to remote, and local helm repositories. You can increase the value files by changing the ApplicationSet YAML file.

With just one ApplicationSet Object, child Application objects will be created and they will install in the clusters with definition files created under the mono or multi repo.

I prevented child Application objects generated deployment or any other resources from being deleted.

## Architecture

The architecture has quite complicated sides in it. Because it is making all changes in just one object, and from it, child objects will be created for each cluster.

Originally [**app of apps pattern**](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/#app-of-apps-pattern) was the idea that came to my mind, but after discovering ApplicationSet and its generators, I could invent an idea to solve for almost any case and apply it to numerous clusters within(or with many) repos, and the biggest advantage is to use argocd-vault-plugin to deploy applications without putting their secrets to git.

Let's check the ApplicationSet.yaml to understand the concept better.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: cluster-apps
spec:
  goTemplate: true
  # This option will prevent child Applications to be deleted.
  syncPolicy:
    preserveResourcesOnDeletion: true
  generators:
    # This is the most important part of the architecture itself. In the Application.yaml files,
    # there are definitions for both what # will be deployed in to the cluster, and how it will
    # be. Under the clusters folder, for each app, you will have a folder. For each app folder,
    # you will put a declarative Application.yaml file which holds information about how the app
    # will be deployed. As a local or remote helm chart, or just standard YAML manifests
    - git:
        repoURL: https://github.com/burhanuguz/advanced-argocd-gitops.git
        revision: HEAD
        files:
          - path: 'clusters/*/*/Application.yaml'
  template:
    # Application Objects will be created with cluster name and application name concatenated.
    metadata:
      name: '{{ index .path.segments 1 }}-{{ .appName }}'
      namespace: argo-cd
      annotations:
        # There is an option for syncOrder as well, to sync applications in a more professional
        # way. Unfortunately, this feature can not be used with Applications that are created
        # with Application Sets in the current version of ArgoCD. I put that anyway if it could
        # be used in the future. # There are some issues opened for this one. It will be much
        # better option once they are GA. It will be possible to bootstrap a cluster very easily
        # in the future with application dependencies.
        argocd.argoproj.io/sync-wave: '{{ .syncOrder }}'
        # There are high availability considerations for monorepos. I tried to put best practices
        # as much as I can. This one prevents Application syncs if no file is changed inside the
        # Application's own folder. It is especially useful with monorepo's.
        # Read more at
        # https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#monorepo-scaling-considerations  
        argocd.argoproj.io/manifest-generate-paths: '.'
      labels:
        clustername: '{{ index .path.segments 1 }}'
        app: '{{ default "" .chartName }}'
    spec:
      # The automated sync policy can be placed, but it will sync all of the apps that are created
      # with Application Set. I tried to make it declarative as well, but you can not declare fields
      # other than String fields and we need object field. For now I would sugget you to create your
      # own solution with argocd cli or use the solution in the other branch that uses helm chart
      # which adds another layer for creating Application objects in cluster. But you can declare
      # anything with it 
      #
      # There are some issues opened as Advanced Application Set templating, when that happens,
      # I will change the definitions here. You will be able to declare anything to App Objects.
      syncPolicy:
        syncOptions:
        - ServerSideApply=true
      #   automated: {}
      # You can also create projects for ArgoCD to limit which resources can be deployed into
      # the cluster. This is a better solution when Application Developers try to do deployments.
      # It will limit which resources they can create and what they will see in the UI as well.
      destination:
        name: '{{ index .path.segments 1 }}'
        namespace: '{{ .namespace }}'
      project: '{{ .argoProject }}'
      source:
        # Here is the magic part that lets you define the multiple repos for each # application.
        # You can use it to store your manifests, helm charts, or external value files in a
        # different repo.
        repoURL: '{{ .repo }}'
        targetRevision: '{{ .branch }}'
        # Here is the folder that application manifests or helm values will be stored for each
        # application.
        path: '{{ .path.path }}'
        plugin:
          env:
            - name: clusterName
              value: '{{ name }}'
            # Determines whether helm local or remote or just application manifest to be deployed
            - name: pluginName
              value: '{{ .plugin }}'
            # Determines which vault will be used for an app.
            # Read at https://argocd-vault-plugin.readthedocs.io/en/stable/backends/
            - name: AVP_SECRET
              value: '{{ default "" .keyVault }}'
            # These values are needed when either local or remote helm plugin is used
            - name: chartName
              value: '{{ default "" .chartName }}'
            - name: chartReleaseName
              value: '{{ default "" .appName | trunc 53 }}'
            ## chartRepository and chartVersion values are needed when helm remote plugin is used
            - name: chartRepository
              value: '{{ default "" .chartRepository }}'
            - name: chartVersion
              value: '{{ default "" .chartVersion }}'
            ## You can put extra args with spaces.
            - name: extraArgs
              value: '{{ default "" .extraArgs }}'
```

And here is the application manifest file that will be deployed. Here is where you can do the trick for mono or multi repo

```yaml
# Can be in different repo, but you have to keep the same folder structure in the repo you define
repo: https://github.com/burhanuguz/advanced-argocd-gitops.git
# Three types of plugins are defined. argocd-vault-plugin, argocd-vault-plugin-helm-local-repo
# and argocd-vault-plugin-helm-remote-repo. 
plugin: 'argocd-vault-plugin-helm-remote-repo'
# As explained, you can use it to limit which resources are to be deployed.
argoProject: 'default'
# Although it does not work with Application Set for now, syncOrder will be an important parameter.
# in the future. It will do the sync with the order. It will useful when you have some dependencies
# and sync to be at first. It will make it much easier to bootstrap clusters in the future.
syncOrder: '0'
# The branch can be defined as well.
branch: 'main'
# This will be the release name.
appName: 'argocd'
## These values are needed when the helm plugin is used. All values are
## already explains itself.
chartName: 'argo-cd'
chartRepository: 'https://argoproj.github.io/argo-helm'
# It is not needed if the chart is in the repository.
chartVersion: '5.5.6'
# Which namespace to deploy.
namespace: 'argocd'
# Which keyVault secret, i.e which Vault will be used for the app? Not necessary to put.
# You can delete it if you don't use it.
keyVault: ''
```

This is all done with a customized plugin below. I have added a plugin as a sidecar and added this YAML file to **configMap** because it is not an actual Kubernetes resource. There is a value YAML inside of this repository you can check.
You can add this and the argocd-vault-plugin binary to the sidecar's image and use it like that. That solution will make your configuration support on-premise environments as well.
Read more at: [Configure plugin via sidecar](https://argo-cd.readthedocs.io/en/stable/user-guide/config-management-plugins/#option-2-configure-plugin-via-sidecar)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ConfigManagementPlugin
metadata:
  name: argocd-vault-plugin
spec:
  lockRepo: false
  allowConcurrency: true
  discover:
    ## Discover command catches if the application will be created with the plugin or not.
    find:
      command:
        - bash
        - "-c"
        - "[[ ${ARGOCD_ENV_pluginName} =~ ^argocd-vault-plugin(|-helm-local-repo|-helm-remote-repo)$ ]] && echo 'OK'"
  generate:
    command:
      - bash
      - "-c"
      - |
        rootFolder=$(pwd | cut -d "/" -f-4)
        
        # The vault plugin binary will use the secret name defined in the Application.yaml
        # If the keyVault value is empty, the command will not be defined and vault plugin
        # not be used. It will just generate manifest files.
        [[ -n "${ARGOCD_ENV_AVP_SECRET}" ]] && avpCommand="| argocd-vault-plugin generate -s ${ARGOCD_ENV_AVP_SECRET} -"
        
        # Values YAML's in the order will be checked if they are there or not. If not, they
        # will not be added in the externalYamlFiles parameter. You can declare two values
        # YAML. A common/base YAML file for all clusters, and cluster specific YAML file
        # which would be inside of the Application's own path.
        for valuesYaml in "${rootFolder}/commonValues/${ARGOCD_ENV_chartReleaseName}/values.yaml" "values.yaml"; do
          [[ -f ${valuesYaml} ]] && externalYamlFiles="$externalYamlFiles --values ${valuesYaml}"
        done
        
        # Helm base command for both a chart in it's own remote helmrepo, or in a git repository.
        helmBaseCommand="helm template --name-template ${ARGOCD_ENV_chartReleaseName} --namespace ${ARGOCD_APP_NAMESPACE} --kube-version ${KUBE_VERSION} --api-versions ${KUBE_API_VERSIONS//,/ --api-versions } ${externalYamlFiles} ${ARGOCD_ENV_extraArgs}"
        # Helm chart location when helm chart in the git repository.
        helmLocalChart="${rootFolder}/charts/$ARGOCD_ENV_chartName/"
        # Remote helm charts need releaseName, repo, and version defined to template them
        helmRemoteChart="${ARGOCD_ENV_chartName} --repo ${ARGOCD_ENV_chartRepository} --version ${ARGOCD_ENV_chartVersion}"
        
        # Dependency update should be done for local charts if they have dependencies
        helmLocalDependency="helm dependency update ${helmLocalChart} 2>&1 >/dev/null;"
        
        # If-else structure to determine which command should be executed
        if [[ "${ARGOCD_ENV_pluginName}" == 'argocd-vault-plugin' ]]; then
          command='find . -regex .*\.ya?ml ! -name Application.y*ml -exec bash -c "cat {}; echo; echo ---" \;'
        elif [[ "${ARGOCD_ENV_pluginName}" == 'argocd-vault-plugin-helm-local-repo' ]]; then
          command="${helmLocalDependency} ${helmBaseCommand} ${helmLocalChart}"
        elif [[ "${ARGOCD_ENV_pluginName}" == 'argocd-vault-plugin-helm-remote-repo' ]]; then
          command="${helmBaseCommand} ${helmRemoteChart}"
        fi
        
        # Evaluate the command
        eval ${command} ${avpCommand}
```

Here is the folder hierarchy. It has local and remote helm repositories, Kubernetes manifest YAML files, and deploying to specific clusters examples in it all at once.

```bash
📦advanced-argocd-gitops/                # 📦Git Folder
 ├── 📜ApplicationSet.yaml               ## ├── 📜ApplicationSet manifest file that creates a child Application object for each definition will be done under the app folder.
 ├── 📂charts                            ## ├── 📂Charts folder for apps helm repos. Add the helm chart here as a folder
 │   └── 📂hello-world-0.1.0             ## │   └── 📂Hello World helm chart added as an example with version
 │       ├── 📜.argocd-allow-concurrency ## │       ├── 📜Add .argocd-allow-concurrency for best practice. Read here https://argo-cd.readthedocs.io/en/stable/operator-manual/high_availability/#enable-concurrent-processing
 │       ├── 📂..........                ## │       ├── 📂Helm Chart specific files/folders
 │       └── 📜..........                ## │       └── 📜Helm Chart specific files/folders
 ├── 📂clusters                          ## ├── 📂Add clusters and app definitions here. They will be generated for each cluster by ApplicationSet
 │   ├── 📂cluster-1                     ## │   ├── 📂'cluster-1' will get deployments defined in the folders under it.
 │   │   ├── 📂app-1                     ## │   │   ├── 📂Remote Helm Chart example. Base value will be used for this app. Check commonValues below.
 │   │   │   ├── 📜Application.yaml      ## │   │   │   ├── 📜Application.yaml file that holds the information about the helloworld remote Helm Chart.
 │   │   │   └── 📜values.yaml           ## │   │   │   └── 📜app-1 helm values yaml for cluster-1
 │   │   ├── 📂app-1-namespace           ## │   │   ├── 📂Creating namespace for newly created helloworld app with limit ranges and quota
 │   │   │   ├── 📜Application.yaml      ## │   │   │   ├── 📜Application.yaml file that holds the information for applying manifests to the clusters
 │   │   │   ├── 📜limitrange.yaml       ## │   │   │   ├── 📜app-1-namespace cluster-1 specific manifest yamls
 │   │   │   ├── 📜namespace.yaml        ## │   │   │   ├── 📜app-1-namespace cluster-1 specific manifest yamls
 │   │   │   └── 📜resourcequota.yaml    ## │   │   │   └── 📜app-1-namespace cluster-1 specific manifest yamls
 │   │   ├── 📂app-2                     ## │   │   ├── 📂Remote Helm Chart example. Base value will be used for this app. Check commonValues below.
 │   │   │   ├── 📜Application.yaml      ## │   │   │   ├── 📜Application.yaml file that holds the information about the helloworld remote Helm Chart.
 │   │   │   └── 📜values.yaml           ## │   │   │   └── 📜app-2 helm values yaml for cluster-1
 │   │   └── 📂app-2-namespace           ## │   │   └── 📂Creating namespace for newly created helloworld app with limit ranges and quota
 │   │       ├── 📜Application.yaml      ## │   │       ├── 📜Application.yaml file that holds the information for applying manifests to the clusters
 │   │       ├── 📜limitrange.yaml       ## │   │       ├── 📜app-2-namespace cluster-1 specific manifest yamls
 │   │       ├── 📜namespace.yaml        ## │   │       ├── 📜app-2-namespace cluster-1 specific manifest yamls
 │   │       └── 📜resourcequota.yaml    ## │   │       └── 📜app-2-namespace cluster-1 specific manifest yamls
 │   ├── 📂cluster-2                     ## │   ├── 📂'cluster-2' will get deployments defined in the folders under it.
 │   │   ├── 📂app-1                     ## │   │   ├── 📂Remote Helm Chart example. Base value will be used for this app. Check commonValues below.
 │   │   │   ├── 📜Application.yaml      ## │   │   │   ├── 📜Application.yaml file that holds the information about the helloworld remote Helm Chart.
 │   │   │   └── 📜values.yaml           ## │   │   │   └── 📜app-1 helm values yaml for cluster-2
 │   │   └── 📂app-1-namespace           ## │   │   └── 📂Creating namespace for newly created helloworld app with limit ranges and quota
 │   │       ├── 📜Application.yaml      ## │   │       ├── 📜Application.yaml file that holds the information for applying manifests to the clusters
 │   │       ├── 📜limitrange.yaml       ## │   │       ├── 📜app-1-namespace cluster-2 specific manifest yamls
 │   │       ├── 📜namespace.yaml        ## │   │       ├── 📜app-1-namespace cluster-2 specific manifest yamls
 │   │       └── 📜resourcequota.yaml    ## │   │       └── 📜app-1-namespace cluster-2 specific manifest yamls
 │   └── 📂in-cluster                    ## │   └── 📂I will maintain ArgoCD and other master cluster resources from here. In case anything happens to the master cluster, it will help us quickly install everything again with minimal downtime.
 │       ├── 📂argocd                    ## │       ├── 📂Remote Argo CD Helm Chart example to manage ArgoCD within ArgoCD
 │       │   ├── 📜Application.yaml      ## │       │   ├── 📜Application.yaml file that holds the information about the ArgoCD remote Helm Chart.
 │       │   └── 📜values.yaml           ## │       │   └── 📜All ArgoCD values
 │       └── 📂ingress-nginx             ## │       └── 📂Nginx ingress controller remote Helm Chart
 │           ├── 📜Application.yaml      ## │           ├── 📜Application.yaml file that holds the information about the Nginx ingress controller remote Helm Chart.
 │           └── 📜values.yaml           ## │           └── 📜Nginx ingress controller values
 └── 📂commonValues                      ## └── 📂Add base values of applications for all clusters here
     └── 📂app-1                         ##     └──📂app-1 commonValues for all clusters.
         └── 📜values.yaml               ##        └── 📜values.yaml that holds common values.
```

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

## Summary

In summary, you can add numerous clusters in mono/multi mix git repositories and manage them with the vault plugin as well.
I absolutely recommend you have one vault backed for the master cluster, and put cluster credentials and other keyVault secrets into the vault as well. Apply those credentials and secrets via Vault, and you will never need to redefine it even if you lose the clusters because you already defined it and manage it via GitOps :)
Also, you can manage even Cilium, OPA, service mesh, and other tools via ArgoCD.

You can separate Vaults, and each app repo for each cluster you want to deploy. You can create ArgoCD projects and declare them in Application.yaml files. You would give access to very few resources in that project. And inside of the Application.yaml, you can declare another repo that application developers would use. Application developers can add their manifests or values yaml and can't create resources they are not allowed to. You could make it in automated way and keep clusters state in the main repo only, and get the values outside of that repo.

Helm local/remote charts with external value deployments + Kubernetes Manifests Deployments + With/Without Vault Plugins and you can dig into one app of a cluster at any time.

It is just to show how powerful ArgoCD can be. Hope it can inspire and be useful to readers.

Cheers :)
