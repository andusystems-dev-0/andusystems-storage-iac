# Installs MetalLB Helm Chart for CRDs
resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = "0.15.3"
  namespace  = "metallb"

  create_namespace = true
}