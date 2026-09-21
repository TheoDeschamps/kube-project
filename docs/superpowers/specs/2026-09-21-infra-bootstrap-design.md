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

### Transport Ansible : control node sur kube-1 (révisé après découverte réelle)

Décision initiale : SSH + ProxyJump via kube-1 depuis le poste de contrôle
(laptop). **Invalidée par la découverte réelle de l'infra** (2026-09-21) :

- Le security group (`sg-004c3459ff99cf637`) n'autorise en entrée que les
  ports 80/443 depuis Internet — le port 22 n'est **jamais** ouvert
  publiquement, par design (cohérent avec "SSM au lieu de SSH public" dans
  le sujet). SSH direct depuis le laptop vers kube-1 est donc impossible,
  et on ne rouvre pas ce port (irait à l'encontre de l'esprit sécurité du
  projet, qui note justement ça).
- Le rôle IAM étudiant n'autorise que la session SSM interactive de base
  (`ssm:StartSession` sur le document par défaut) — ni `ssm:SendCommand`,
  ni les documents `AWS-StartSSHSession`/`AWS-StartPortForwardingSession`
  (testés, tous refusés). Impossible de tunneliser du SSH via SSM non plus.

Solution retenue : **Ansible tourne directement sur kube-1** (l'alternative
initialement écartée pour confort de workflow). kube-1 → kube-2/kube-3 en
SSH sur IP privée est déjà couvert par la règle "all traffic from self" du
security group. kube-1 a un accès Internet sortant, donc il peut cloner le
dépôt Git (poussé sur un repo GitHub public dédié) et s'auto-suffire. Zéro
permission AWS supplémentaire nécessaire au-delà de la session SSM de base,
déjà confirmée fonctionnelle.

La clé SSH publique du projet a été déployée manuellement sur les 3 nœuds
via une session SSM interactive + `sudo tee` (le script `send-command`
automatisé du plan initial ne fonctionne pas, cf. ci-dessus). La clé privée
est copiée sur kube-1 pour lui permettre d'initier le SSH sortant vers
kube-2/kube-3.

Plugin de connexion `aws_ssm` (écarté à nouveau) : aurait évité ce détour,
mais nécessite un bucket S3 pour le transfert de fichiers et un rôle IAM
d'instance dédié — plus de surface de permissions à valider, alors que la
solution "control node sur kube-1" ne demande rien de plus que ce qui est
déjà confirmé fonctionnel.

### Bootstrap des clés SSH : script SSM, hors Ansible

Ansible ne peut pas se connecter avant qu'une clé SSH existe sur les VMs —
donc un script séparé (`aws ssm send-command` avec le document
`AWS-RunShellScript`) pousse la clé publique dans `~/.ssh/authorized_keys`
sur les 3 instances en une seule fois. Ce script est versionné et documenté
dans le repo (pas un geste manuel non reproductible).

### Inventaire : statique (révisé — c'était le plan B)

Avec Ansible qui tourne sur kube-1 lui-même, l'inventaire dynamique
`amazon.aws.aws_ec2` perdrait son intérêt principal (éviter la maintenance
manuelle des IPs) tout en ajoutant un vrai inconvénient : il faudrait
stocker des identifiants AWS SSO sur kube-1, une machine plus exposée que le
laptop. On utilise donc un inventaire statique (`inventory.ini`), avec
seulement les IP privées de kube-2/kube-3 (kube-1 se gère lui-même en
`ansible_connection: local`). Si les IPs privées changent après un arrêt
nocturne (à vérifier en pratique), l'inventaire est mis à jour à la main —
c'était déjà la solution de repli documentée dans la première version de
cette décision.

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
     `--control-plane-endpoint` pointant l'**IP privée** de kube-1 (corrigé
     après un échec réel : une instance AWS ne peut pas se joindre
     elle-même via son IP publique — pas de hairpin NAT sur l'IGW — donc
     kubelet timeout indéfiniment en essayant d'atteindre l'apiserver sur
     l'IP publique. L'IP privée est stable "inside the VPC" et joignable par
     les 3 nœuds. L'accès externe au control plane, si nécessaire plus tard,
     passera par un autre mécanisme) ;
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
