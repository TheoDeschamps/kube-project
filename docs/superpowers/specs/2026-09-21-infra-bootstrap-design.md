# Sous-projet 1 — Accès & bootstrap infra

Statut : validé par l'utilisateur, en attente de relecture finale avant passage au plan d'implémentation.

## Contexte

Projet Epitech "Kube" : déploiement d'un cluster Kubernetes complet (infra +
application convertie depuis docker-compose) sur 3 VMs AWS fournies par
l'école (`kube-1`, `kube-2`, `kube-3`). Ce document couvre uniquement le
premier sous-projet du découpage global : obtenir un accès fiable aux VMs et
provisionner le cluster Kubernetes lui-même via Ansible. Les sous-projets
suivants (socle GitOps, sécurité/OIDC, application, démo) font l'objet de
specs séparées.

## Contraintes imposées par le sujet

- Provisioning du cluster avec Ansible (imposé).
- `kube-1` = control plane + worker, IP publique stable qui survit aux
  arrêts nocturnes. `kube-2`/`kube-3` = workers, IP publique instable (change
  à chaque redémarrage), IP privée VPC stable.
- Accès VM via AWS SSM Session Manager (IAM Identity Center, email école),
  pas de clé SSH par défaut. Déployer ses propres clés SSH par-dessus est
  autorisé et recommandé par le sujet lui-même.
- Toutes les VMs s'éteignent chaque soir automatiquement ; redémarrage
  possible à tout moment.
- Le cluster doit pouvoir être détruit et reconstruit de façon reproductible
  (exigence explicite + démo live "provisioning a fresh cluster with
  Ansible").

## Décisions

### Distribution Kubernetes : kubeadm (vanilla)

Choisi plutôt que k3s/k0s pour garder chaque composant explicite et
justifiable en soutenance (le sujet évalue la compréhension de la
responsabilité de chaque brique). k3s aurait imposé de désinstaller
Traefik/ServiceLB/local-path-provisioner embarqués par défaut, ce qui va à
l'encontre des choix d'ingress/stockage qui seront faits dans les
sous-projets suivants.

### CNI : Calico

Compatible kubeadm, supporte nativement les NetworkPolicy (utile pour le
bonus "reinforcement of network access").

### Transport Ansible : SSH + ProxyJump via kube-1

`kube-2`/`kube-3` n'ont pas d'IP publique stable, donc injoignables
directement depuis le poste de contrôle (laptop). `kube-1` sert de jump host
(IP publique stable + IP privée dans le même VPC que kube-2/3).

Alternatives écartées :
- Ansible control node sur kube-1 lui-même : viable mais workflow moins
  pratique pour itérer depuis l'éditeur local.
- Plugin de connexion `aws_ssm` : évite la gestion de clés SSH mais ajoute
  des dépendances (session-manager-plugin, boto3/botocore, bucket S3 pour le
  transfert de fichiers). Non retenu pour la simplicité.

### Bootstrap des clés SSH : script SSM, hors Ansible

Ansible ne peut pas se connecter avant qu'une clé SSH existe sur les VMs —
donc un script séparé (`aws ssm send-command` avec le document
`AWS-RunShellScript`) pousse la clé publique dans `~/.ssh/authorized_keys`
sur les 3 instances en une seule fois. Ce script est versionné et documenté
dans le repo (pas un geste manuel non reproductible).

### Inventaire : dynamique (`amazon.aws.aws_ec2`), avec un inventaire statique documenté en secours

Les IP privées de kube-2/kube-3 ne sont pas garanties stables après un
redémarrage (à vérifier lors de la découverte — le sujet dit stables "inside
the VPC", mais un inventaire dynamique reste plus sûr et zéro-maintenance).
Le plugin d'inventaire dynamique AWS interroge l'API EC2 à chaque run
Ansible. Un inventaire statique (`inventory.ini` à mettre à jour à la main)
reste documenté comme solution de repli si le dynamique pose problème
(droits IAM, dépendances Python, etc.).

### Structure de repo : monorepo unique fourni par Epitech

Un seul repo de livraison (imposé par l'école). Deux dossiers à la racine :

```
/
├── infra/
│   ├── ansible/        <- playbooks + script de bootstrap SSH (ce sous-projet)
│   └── gitops/          <- manifests kustomize + config opérateur GitOps (sous-projet 2+)
├── app/                  <- Helm chart + repo GitOps applicatif (sous-projet 4)
└── docs/                 <- documentation, specs de conception
```

Le mirroir GitHub personnel de l'utilisateur reproduit la même structure et
pousse vers le repo école sur une branche à son nom.

## Étapes

1. **Découverte** — via la console AWS ou `aws ec2 describe-instances`
   (après `aws sso login`) : instance IDs, IP publique de kube-1, IPs privées
   des 3 nœuds, AMI/OS, vérification que les security groups autorisent le
   SSH entre kube-1 et kube-2/3 en interne.
2. **Bootstrap SSH** — génération d'une paire de clés dédiée au projet,
   script `send-command` SSM pour la déployer sur les 3 VMs.
3. **Inventaire dynamique** — configuration du plugin `amazon.aws.aws_ec2`
   avec les credentials AWS SSO, groupé par tag/nom d'instance
   (`kube-1`/`kube-2`/`kube-3`), variable `ansible_ssh_common_args` avec
   `ProxyJump` vers kube-1 pour les workers.
4. **Playbook kubeadm** — rôles :
   - `common` : paquets de base, désactivation du swap, sysctl requis par
     Kubernetes ;
   - `containerd` : runtime de conteneurs ;
   - `kubeadm-init` : exécuté uniquement sur kube-1, avec
     `--control-plane-endpoint` pointant l'IP publique stable de kube-1 (pour
     rester valide après redémarrage) ;
   - `kubeadm-join` : exécuté sur kube-2/kube-3 ;
   - installation de Calico (CNI) après l'init.
5. **Vérification** — `kubectl get nodes` doit montrer 3 nœuds `Ready`. Le
   playbook doit être ré-exécutable sans casser un cluster existant
   (idempotence) — vérifié par un second run sans changement signalé sur les
   tâches déjà appliquées.

## Hors périmètre (sous-projets suivants)

- Ingress/Gateway API, dashboard, monitoring, logging, opérateur GitOps lui-même (sous-projet 2).
- OIDC (dex + Keycloak), ValidatingAdmissionPolicy (sous-projet 3).
- Conversion de l'application, Helm chart, repo GitOps applicatif (sous-projet 4).
- Préparation de la démo/soutenance (sous-projet 5).

## Risques / points à vérifier à l'implémentation

- Les security groups par défaut de kube-2/3 pourraient ne pas autoriser le
  SSH entrant depuis kube-1 en interne — à vérifier lors de la découverte, à
  corriger manuellement si besoin (hors scope Ansible, config AWS).
- Le plugin d'inventaire dynamique nécessite `boto3`/`botocore` et des
  identifiants AWS valides sur le poste de contrôle (SSO) — à documenter
  dans le README du dossier `ansible/`.
