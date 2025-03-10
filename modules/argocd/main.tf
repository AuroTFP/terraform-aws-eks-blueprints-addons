module "helm_addon" {
  count  = !var.argocd_skip_install ? 1 : 0
  source = "../helm-addon"

  helm_config   = local.helm_config
  addon_context = var.addon_context

  depends_on = [kubernetes_namespace_v1.this]
}

resource "kubernetes_namespace_v1" "this" {
  count = length(var.addon_config) != 0 && try(local.helm_config["create_namespace"], true) && local.helm_config["namespace"] != "kube-system" ? 1 : 0
  metadata {
    name = local.helm_config["namespace"]
  }
}

# ---------------------------------------------------------------------------------------------------------------------
# ArgoCD App of Apps Bootstrapping (Helm)
# ---------------------------------------------------------------------------------------------------------------------
resource "helm_release" "argocd_application" {
  for_each = { for k, v in var.applications : k => merge(local.default_argocd_application, v) if merge(local.default_argocd_application, v).type == "helm" }

  name      = each.key
  chart     = "${path.module}/argocd-application/helm"
  version   = "1.0.0"
  namespace = local.helm_config["namespace"]
  timeout   = local.helm_config["timeout"]

  # Application Meta.
  set {
    name  = "name"
    value = each.key
    type  = "string"
  }

  set {
    name  = "project"
    value = each.value.project
    type  = "string"
  }

  # Source Config.
  set {
    name  = "source.repoUrl"
    value = each.value.repo_url
    type  = "string"
  }

  set {
    name  = "source.targetRevision"
    value = each.value.target_revision
    type  = "string"
  }

  set {
    name  = "source.path"
    value = each.value.path
    type  = "string"
  }

  set {
    name  = "source.helm.releaseName"
    value = each.key
    type  = "string"
  }

  set {
    name = "source.helm.values"
    value = yamlencode(merge(
      { repoUrl = each.value.repo_url },
      each.value.values,
      local.global_application_values,
      { for k, v in var.addon_config : k => v if each.value.add_on_application }
    ))
    type = "auto"
  }

  # Destination Config.
  set {
    name  = "destination.server"
    value = each.value.destination
    type  = "string"
  }

  set {
    name  = "namespace"
    value = each.value.namespace
    type  = "string"
  }

  values = [
    # Application ignoreDifferences
    yamlencode({
      "ignoreDifferences" = lookup(each.value, "ignoreDifferences", [])
    })
  ]

  depends_on = [module.helm_addon, helm_release.argocd_project]
}

# ---------------------------------------------------------------------------------------------------------------------
# ArgoCD Projects Bootstrapping
# ---------------------------------------------------------------------------------------------------------------------
resource "helm_release" "argocd_project" {
  for_each = { for k, v in var.projects : k => merge(local.default_argocd_project, v) }

  name      = each.key
  chart     = "${path.module}/argocd-project/helm"
  version   = "1.0.0"
  namespace = each.value.namespace

  # Application Meta.
  set {
    name  = "name"
    value = each.key
    type  = "string"
  }

  set {
    name  = "description"
    value = each.value.description
    type  = "string"
  }

  values = [
    # ArgoCD Project Spec
    yamlencode({
      "destinations"               = lookup(each.value, "destinations", [])
      "clusterResourceWhitelist"   = lookup(each.value, "cluster_resource_whitelist", [])
      "namespaceResourceBlacklist" = lookup(each.value, "namespace_resource_blacklist", [])
      "namespaceResourceWhitelist" = lookup(each.value, "namespace_resource_whitelist", [])
      "roles"                      = lookup(each.value, "roles", [])
      "syncWindows"                = lookup(each.value, "sync_windows", [])
      "sourceNamespaces"           = lookup(each.value, "source_namespaces", [])
      "sourceRepos"                = lookup(each.value, "source_repos", [])
    })
  ]

  depends_on = [module.helm_addon]
}

# ---------------------------------------------------------------------------------------------------------------------
# ArgoCD App of Apps Bootstrapping (Kustomize)
# ---------------------------------------------------------------------------------------------------------------------
resource "kubectl_manifest" "argocd_kustomize_application" {
  for_each = { for k, v in var.applications : k => merge(local.default_argocd_application, v) if merge(local.default_argocd_application, v).type == "kustomize" }

  yaml_body = templatefile("${path.module}/argocd-application/kubectl/application.yaml.tftpl",
    {
      name                 = each.key
      namespace            = each.value.namespace
      project              = each.value.project
      sourceRepoUrl        = each.value.repo_url
      sourceTargetRevision = each.value.target_revision
      sourcePath           = each.value.path
      destinationServer    = each.value.destination
      ignoreDifferences    = lookup(each.value, "ignoreDifferences", [])
      useRecurse           = each.value.use_recurse
    }
  )

  depends_on = [module.helm_addon]
}

# ---------------------------------------------------------------------------------------------------------------------
# Private Repo Access
# ---------------------------------------------------------------------------------------------------------------------

resource "kubernetes_secret" "argocd_gitops" {
  for_each = { for k, v in var.applications : k => v if try(v.ssh_key_secret_name, null) != null }

  metadata {
    name      = lookup(each.value, "git_secret_name", "${each.key}-repo-secret")
    namespace = lookup(each.value, "git_secret_namespace", local.helm_config["namespace"])
    labels    = { "argocd.argoproj.io/secret-type" : "repository" }
  }

  data = {
    insecure      = lookup(each.value, "insecure", false)
    sshPrivateKey = data.aws_secretsmanager_secret_version.ssh_key_version[each.key].secret_string
    type          = "git"
    url           = each.value.repo_url
  }

  depends_on = [module.helm_addon]
}
