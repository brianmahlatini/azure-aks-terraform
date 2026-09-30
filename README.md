# azure-aks-terraform

A hardened Azure Kubernetes Service platform in Terraform: Entra ID-only cluster access, Azure CNI Overlay with Cilium network policy, workload identity for pods, ACR image pulls through a managed identity, Key Vault through the Secrets Store CSI driver, and Container Insights. Every security property is covered by an offline test with a mocked `azurerm` provider.

```
$ make test
==> modules/aks   Success! 12 passed, 0 failed.
$ make security
Passed checks: 32, Failed checks: 0, Skipped checks: 13   # each skip is justified inline
```

## Architecture

```
  Entra ID ──(Azure RBAC, groups)──► AKS API server  ◄── authorized IP ranges only
                                         │
            ┌────────────────────────────┼─────────────────────────────┐
            │ system pool (3 zones)       │ user pool (3 zones)          │
            │ CriticalAddonsOnly taint    │ Regular or Spot (tainted)    │   nodes: /20 subnet + NSG
            └────────────────────────────┴─────────────────────────────┘   pods: 192.168.0.0/16 overlay
                                         │
     kubelet identity ──AcrPull──► ACR (admin user disabled)
     app ServiceAccount ──OIDC federation──► user-assigned identity ──Secrets User──► Key Vault (RBAC, purge protection, default Deny)
     Container Insights ──► Log Analytics
```

## Design decisions and trade-offs

- **No static credentials anywhere.** `local_account_disabled = true` removes the cluster-admin kubeconfig. People authenticate through Entra ID groups, pods through workload identity (projected service-account token exchanged for an Entra token), and nodes pull from ACR with their kubelet identity. There's no ACR admin password, no client secret in the cluster, and no secret in Terraform state.
- **User-assigned identities, not system-assigned.** They exist before the cluster, so `AcrPull`, `Network Contributor` on the subnet and `Managed Identity Operator` are granted before the first node boots. That avoids the classic race where the first image pull fails. They also survive a cluster rebuild, so role assignments don't churn.
- **Azure CNI Overlay + Cilium.** Pods get addresses from an overlay range instead of the VNet, so a /20 node subnet scales to thousands of pods without VNet re-planning. The Cilium data plane enforces Kubernetes `NetworkPolicy` with eBPF.
- **System/user pool split.** System add-ons run on a small tainted pool. App pods can't starve CoreDNS or the metrics server, and the user pool can scale to zero or run on Spot.
- **Spot for dev, safely.** Spot pools are tainted, so only workloads that tolerate eviction land there. `spot_max_price = -1` means nodes are only reclaimed for capacity, never because the market price rose.
- **Guardrail against an open API server.** An API server reachable from anywhere fails at plan time unless you set `allow_public_api = true` explicitly. Unsafe defaults have to be a deliberate choice.
- **Upgrades on autopilot, within limits.** The `patch` channel applies Kubernetes security patches and `NodeImage` rolls patched OS images weekly, both in a Sunday maintenance window. Minor-version upgrades stay a reviewed code change. Surge upgrades (33%) keep capacity during rollouts.
- **Cost vs resilience, as variables.** `sku_tier` (Free vs Standard SLA), `acr_sku` (Premium adds zone redundancy and private endpoints), `private_cluster_enabled` and Spot are all inputs, so dev stays cheap and prod gets the resilient options without forking the module.

## Testing strategy

| Layer | Tool |
|---|---|
| Formatting and schema | `terraform fmt`, `terraform validate` on the module and the env root |
| Behaviour | `terraform test` with `mock_provider "azurerm"`: RBAC and local accounts, API allow-list, overlay/Cilium, pool isolation, Spot taints, identity wiring and scopes, Key Vault protection, input guardrails |
| Lint | `tflint` + azurerm ruleset (invalid VM sizes, deprecated arguments) |
| Security | `checkov` |
| Real plan | `terraform plan` through GitHub OIDC → Entra ID, when `AZURE_CLIENT_ID` is configured |

## Usage

```sh
cd envs/dev
cp backend.hcl.example backend.hcl
terraform init -backend-config=backend.hcl
terraform apply -var 'operator_cidrs=["203.0.113.10/32"]'
$(terraform output -raw get_credentials)
kubectl get nodes
```

Annotate the app's service account with `azure.workload.identity/client-id: <workload_identity_client_id>` and label its pods `azure.workload.identity/use: "true"`. All ids and names in examples and tests are placeholders.

## License

MIT
