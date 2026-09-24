# Project-wide notes & instructor guidance

Cross-cutting requirements and guidance gathered along the way, that apply
across sub-projects rather than to one specific spec. Check this before
starting each new sub-project's brainstorming.

## Milestones

- **2026-09-21** — Follow-up #1: machine configurée, cluster qui tourne,
  moyen d'accès SSH. Satisfait (sous-projet 1 complet).
- **2026-12-15 (mi-décembre)** — Follow-up #2: objectif **90% du projet**
  terminé.

## Instructor guidance log

### 2026-09-21 — Follow-up requirements

"Machine configurée et cluster Kube qui tourne, et un moyen d'accès à la
machine (l'intervenant a parlé de connexion SSH)."

Satisfied by sub-project 1: cluster live (3/3 nodes `Ready`), access via SSM
(official/imposed by the subject) + Tailscale (day-to-day SSH, see
`infra/ansible/README.md`).

### 2026-09-24 — Ansible should support laptop execution via Tailscale

The instructor considers Tailscale a network-layer dependency, **annex to
the project itself** (comparable to a VPN) — not part of the graded
Ansible/Kubernetes provisioning logic. Expectation: Ansible should
eventually be runnable directly from the operator's laptop (not only from
`kube-1`), using Tailscale for reachability, since this is treated as
acceptable standing infrastructure rather than a workaround that would
compromise the "provision a fresh cluster reproducibly" requirement.

**Status: documented, not yet implemented.** Sub-project 1's playbook still
runs from `kube-1` by default — this keeps working with zero dependency on
Tailscale, so provisioning still succeeds even if Tailscale isn't set up
yet (e.g. the very first bootstrap of a brand new environment, before
Tailscale can even be installed, still has to go through SSM). Adding
laptop-based execution as an *alternative* inventory
(`inventory/hosts-tailscale.ini`) is tracked as follow-up work on top of
sub-project 1 — see the note added to
`docs/superpowers/plans/2026-09-21-infra-bootstrap-plan.md`.

Design constraint to respect when implementing this: kubeadm's
`control-plane-endpoint` (the cluster's own internal address, used by
kubelets/kube-proxy/etc.) must stay **decoupled** from whichever address
Ansible uses to *reach* `kube-1` for provisioning. The endpoint stays
`kube-1`'s private AWS IP regardless of whether Ansible connects via
SSM/local-exec (current default) or via Tailscale from the laptop (planned
addition) — don't let `ansible_host` double for both purposes again like it
did originally, that's what would break if the transport address changes.

### 2026-09-24 — Support a new app / fast redeploy

The final project must be able to support changes or a new application,
deployable quickly. This is already the core motivation behind the
architecture choices made so far and planned ahead — no architecture change
needed because of this guidance, it confirms the direction already chosen:

- **GitOps** (ArgoCD/FluxCD, sub-project 2) — a Git push triggers
  reconciliation automatically, no manual redeploy steps.
- **Helm chart** for the application (sub-project 4) — parameterized,
  versioned deployments rather than one-off manifests.
- **Progressive rollout with readiness probes** (required by the subject's
  defense section) — a new version rolls out without downtime and without
  manual intervention if it's healthy.

Treat this as a lens to keep applying when making design decisions in
sub-projects 2-5: favor automation/reproducibility over one-off manual
steps, and be ready to justify how a given choice supports "deploy a new
app / a change, quickly" if asked during the defense.

### 2026-09-24 — Component order within sub-project 2: dashboard, then monitoring

Once the access/configuration groundwork is done (sub-project 1, complete),
the instructor's advised order for the rest is: **config (done) → dashboard
→ monitoring**, ahead of the other components bundled into sub-project 2
(GitOps operator, Ingress, logging, cert-manager, Secrets — order among
those not specified).

**Not yet actioned** — to apply when sub-project 2 is brainstormed: treat
this as the priority order *within* sub-project 2 rather than a reason to
reshuffle the 5-sub-project decomposition itself. Open question to resolve
at that point: does this mean standing up dashboard/monitoring directly
(`helm install`/`kubectl apply`) before the GitOps operator exists, then
folding them under GitOps once the operator is in place — or does the
GitOps operator have to come first anyway (there needs to be *something* to
reconcile their manifests) and "dashboard, then monitoring" just means
they're the first two components the operator reconciles, in that order?
Ask/decide this explicitly at the start of sub-project 2's brainstorming
rather than assuming. Also note Ingress likely needs to land before or
alongside dashboard, since the dashboard needs to be exposed/reachable to
be useful — worth raising then too.
