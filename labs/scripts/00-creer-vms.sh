#!/usr/bin/env bash
# ===========================================================================
# 00-creer-vms.sh — Création des deux machines virtuelles du lab Ansible.
#
# Où l'exécuter : sur le POSTE HÔTE (Linux avec VirtualBox et VBoxManage
# installés), et non dans une VM du lab.
#
# Contexte : en situation de cours, le control node cn-ansible est livré
# déjà équipé et le node web1 est livré vierge. Ce script n'est donc utile
# que pour RECONSTRUIRE intégralement le laboratoire depuis zéro ; il ne
# remplace pas la préparation de web1 décrite à l'étape suivante.
#
# Ce que fait le script :
#   1. vérifie la présence de VBoxManage et de l'image ISO Ubuntu Server ;
#   2. vérifie la présence du réseau interne du lab (ansible-lab) ;
#   3. crée la VM de base cn-ansible (control node) depuis l'ISO ;
#   4. crée le clone web1 à partir de cette VM de base ;
#   5. configure deux interfaces réseau par VM : NAT (accès Internet et
#      redirection du port SSH vers le poste hôte) et réseau interne
#      ansible-lab, qui relie les deux machines entre elles (172.16.0.0/24) ;
#   6. affiche un récapitulatif et demande confirmation avant d'agir.
#
# Choix du réseau : les deux machines sont reliées par un réseau interne
# VirtualBox (ansible-lab). Le poste hôte n'y a pas accès : il rejoint les VM
# par les ports de redirection NAT (2222, 2223), tandis que le control
# node, qui est lui-même une VM, parle au node web1 par 172.16.0.11.
#
# Sécurité : ce script ne modifie que les VM du lab de formation. Il ne
# supprime une VM existante que si l'option --forcer est fournie.
#
# Après ce script (reconstruction intégrale uniquement) :
#   dans web1        : sudo labs/scripts/10-preparer-vm.sh --nom web1 --ip 172.16.0.11
#   dans cn-ansible  : sudo labs/scripts/10-preparer-vm.sh --nom cn-ansible \
#                        --ip 172.16.0.10 --control-node
# ===========================================================================
set -euo pipefail

# --- Constantes du lab (contrat d'adressage non négociable) ------------------
readonly NOM_VM_BASE="cn-ansible"                  # control node : VM installée depuis l'ISO
readonly RESEAU_PRIVE="172.16.0.0/24"              # réseau privé commun aux deux VM
readonly NOM_RESEAU_INTERNE="ansible-lab"          # réseau interne VirtualBox reliant les deux VM
readonly PORT_SSH_DANS_VM=22                       # port SSH du service sshd dans chaque VM
readonly NOM_DOSSIER_LAB="lab-ansible"            # dossier parent des VM du lab dans VirtualBox

# Adresses fixes des deux VM : elles garantissent le même contrat d'adressage
# quel que soit le poste hôte, y compris depuis une autre machine.
readonly -a NOMS_VM=("cn-ansible" "web1")
readonly -a IPS_VM=("172.16.0.10" "172.16.0.11")
# Ports de redirection NAT vers le port 22 de chaque VM, utilisés par
# 20-cle-ssh.sh et par l'accès administrateur depuis le poste.
readonly -a PORTS_NAT=(2222 2223)

# --- Constantes de dimensionnement des VM -----------------------------------
readonly TYPE_NAT="nat"          # type de l'interface 1 : NAT (accès Internet et redirection SSH)
readonly TYPE_PRIVE="intnet"    # type de l'interface 2 : réseau interne du lab
readonly TYPE_OS="Ubuntu_64"      # type d OS déclaré à VBoxManage pour Ubuntu 64 bits
readonly MEMOIRE_MO=2048          # 2 Go : suffisant pour chaque VM du lab
readonly NB_CPU=2                 # 2 cœurs : suffisant pour les tâches du cours
readonly VRAM_MO=32               # vidéo : minimale, le lab est en mode console SSH
readonly TAILLE_DISQUE_MO=16384   # 16 Go : installateur Ubuntu Server + Ansible
readonly FORMAT_DISQUE="VDI"      # format d'image de disque VirtualBox
readonly EXTENSION_DISQUE="vdi"   # extension du fichier de disque
readonly NOM_CONTROLEUR="SATA"    # contrôleur de stockage des VM du lab
readonly NOM_REGLE_NAT="lab-ssh"  # nom de la règle de redirection NAT du port 22
readonly TAILLE_NAT_HOST="127.0.0.1"   # les VM n'écoutent que sur la boucle locale du poste

# --- Valeurs par défaut (modifiables par les options de la ligne de commande) -
ISO="${ISO:-}"                              # image ISO Ubuntu Server (option --iso)
MEMOIRE_MO_UTILISEE="$MEMOIRE_MO"           # mémoire allouée par VM (option --memoire)
NB_CPU_UTILISE="$NB_CPU"                    # nombre de cœurs par VM (option --cpu)
TAILLE_DISQUE_MO_UTILISEE="$TAILLE_DISQUE_MO"   # taille de disque par VM (option --disque)
RACINE_VM="${HOME}/VirtualBox VMs/${NOM_DOSSIER_LAB}"   # dossier parent des VM du lab
FORCER="non"            # recréer une VM déjà présente (option --forcer)
CONFIRMATION_AUTO="non" # ne pas demander de confirmation (option --oui)
SIMULATION="non"        # afficher les commandes sans les exécuter (option --simulation)

# Emplacements cherchés par défaut pour l'image ISO, dans cet ordre.
readonly -a ISO_CANDIDATS=(
  "/srv/iso/ubuntu-24.04-live-server-amd64.iso"
  "/srv/iso/ubuntu-26.04-live-server-amd64.iso"
  "${HOME}/VirtualBox VMs/${NOM_DOSSIER_LAB}/iso/ubuntu-24.04-live-server-amd64.iso"
)

# --- Fonctions de trace ------------------------------------------------------
log()     { printf '[INFO] %s\n' "$*"; }
succes()  { printf '[OK] %s\n' "$*"; }
avert()   { printf '[AVERTISSEMENT] %s\n' "$*" >&2; }
erreur()  { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

# Exécute une commande, ou l'affiche si le mode simulation'est actif.
executer() {
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] %s\n' "$*"
    return 0
  fi
  "$@"
}

# Exécute une commande sans interrompre le script en cas d'échec.
executer_tolerant() {
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] %s\n' "$*"
    return 0
  fi
  "$@" || avert "commande sans effet : $*"
}

usage() {
  cat <<'AIDE'
Utilisation : 00-creer-vms.sh [options]

Crée les deux machines virtuelles du lab Ansible (control node cn-ansible
et node web1) avec VBoxManage. À exécuter sur le poste hôte.

Ce script sert à reconstruire intégralement le laboratoire. En situation de
cours, le control node cn-ansible est livré déjà équipé : il ne faut donc
le recréer que si l'ensemble du lab doit être reconstruit.

Options :
  --iso <chemin>        Image ISO Ubuntu Server à installer.
                        Par défaut, le script cherche un fichier
                        ubuntu*server-amd64.iso dans /srv/iso puis dans
                        le dossier personnel (profondeur 3).
  --memoire <Mo>        Mémoire allouée par VM. Valeur par défaut : 2048.
  --cpu <nombre>        Nombre de cœurs par VM. Valeur par défaut : 2.
  --disque <Mo>         Taille de disque par VM. Valeur par défaut : 16384.
  --dossier-vm <chemin> Dossier parent des VM du lab.
                        Valeur par défaut : ~/VirtualBox VMs/lab-ansible
  --forcer              Supprimer puis recréer une VM déjà existante.
  --oui                 Ne pas demander de confirmation.
  --simulation          Afficher les commandes VBoxManage sans les exécuter.
  -h, --aide, --help    Afficher cette aide.

Topologie créée (contrat d'adressage du lab) :
  machine      adresse privée    port NAT (SSH) sur le poste
  cn-ansible   172.16.0.10       2222
  web1         172.16.0.11       2223

Ordre d'exécution recommandé (reconstruction intégrale) :
  1. sur le poste   : labs/scripts/00-creer-vms.sh
  2. dans web1      : sudo labs/scripts/10-preparer-vm.sh --nom web1 --ip 172.16.0.11
  3. dans cn-ansible (control node reconstruit, option --control-node obligatoire) :
        sudo labs/scripts/10-preparer-vm.sh --nom cn-ansible --ip 172.16.0.10 --control-node
  4. sur cn-ansible : labs/scripts/20-cle-ssh.sh --reseau-prive
  5. sur cn-ansible : sudo labs/scripts/30-projet-demo.sh
  6. sur cn-ansible : labs/scripts/90-verifier-lab.sh
AIDE
}

# --- Analyse des options -----------------------------------------------------
analyser_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--aide|--help)    usage; exit 0 ;;
      --iso)               ISO="${2:?chemin manquant pour --iso}"; shift 2 ;;
      --iso=*)             ISO="${1#*=}"; shift ;;
      --memoire)           MEMOIRE_MO_UTILISEE="${2:?valeur manquante pour --memoire}"; shift 2 ;;
      --memoire=*)         MEMOIRE_MO_UTILISEE="${1#*=}"; shift ;;
      --cpu)               NB_CPU_UTILISE="${2:?valeur manquante pour --cpu}"; shift 2 ;;
      --cpu=*)             NB_CPU_UTILISE="${1#*=}"; shift ;;
      --disque)            TAILLE_DISQUE_MO_UTILISEE="${2:?valeur manquante pour --disque}"; shift 2 ;;
      --disque=*)          TAILLE_DISQUE_MO_UTILISEE="${1#*=}"; shift ;;
      --dossier-vm)        RACINE_VM="${2:?chemin manquant pour --dossier-vm}"; shift 2 ;;
      --dossier-vm=*)      RACINE_VM="${1#*=}"; shift ;;
      --forcer)            FORCER="oui"; shift ;;
      --oui)               CONFIRMATION_AUTO="oui"; shift ;;
      --simulation)        SIMULATION="oui"; shift ;;
      "")                  erreur "argument vide ; utiliser --aide pour la liste des options" ;;
      *)                   erreur "option inconnue : $1 (utiliser --aide)" ;;
    esac
  done
}

# --- Vérifications préalables ------------------------------------------------
verifier_outils() {
  command -v VBoxManage >/dev/null 2>&1 \
    || erreur "VBoxManage est introuvable. Installer VirtualBox puis relancer."
  log "VBoxManage : $(command -v VBoxManage)"
  log "Version de VirtualBox : $(VBoxManage --version)"
}

# Rend le chemin de l'image ISO à utiliser, ou échoue si aucune source n'existe.
trouver_iso() {
  local candidat
  if [ -n "$ISO" ]; then
    printf '%s\n' "$ISO"
    return 0
  fi
  for candidat in "${ISO_CANDIDATS[@]}"; do
    if [ -f "$candidat" ]; then
      printf '%s\n' "$candidat"
      return 0
    fi
  done
  # Dernière recherche : premier fichier nommé ubuntu*server-amd64.iso trouvé
  # dans le dossier personnel, à faible profondeur.
  local -a trouves=()
  mapfile -t trouves < <(find "$HOME" -maxdepth 3 -type f -name 'ubuntu*server-amd64.iso' -print 2>/dev/null | sort)
  if [ "${#trouves[@]}" -gt 0 ]; then
    printf '%s\n' "${trouves[0]}"
    return 0
  fi
  return 1
}

verifier_iso() {
  local chemin
  chemin="$(trouver_iso)" || erreur "aucune image ISO Ubuntu Server trouvée : télécharger une image Ubuntu Server (amd64), puis relancer avec --iso /chemin/vers/ubuntu-24.04-live-server-amd64.iso."
  [ -r "$chemin" ] || erreur "image ISO illisible : $chemin"
  ISO="$chemin"
  log "Image ISO : $ISO"
}

# --- Réseau interne du lab --------------------------------------------------
# Un réseau interne n'existe pas comme un objet à créer : VirtualBox le crée
# automatiquement lorsqu'une machine y est rattachée. Le script se contente
# donc de constater sa présence, sans quoi il annonce la création.
reseau_interne_present() {
  VBoxManage list intnets | grep -qxF "Name:        $NOM_RESEAU_INTERNE"
}

verifier_reseau_interne() {
  if reseau_interne_present; then
    succes "Réseau interne présent : $NOM_RESEAU_INTERNE (trafic privé $RESEAU_PRIVE)."
    return 0
  fi
  log "Réseau interne $NOM_RESEAU_INTERNE absent : VirtualBox le créera au"
  log  "rattachement de la première machine (trafic privé $RESEAU_PRIVE)."
}

# --- Gestion des VM ----------------------------------------------------------
# Une VM enregistrée est listée par VBoxManage sous la forme
#   "nom" {uuid}
vm_deja_presente() {
  VBoxManage list vms | grep -qF "\"$1\" {"
}

supprimer_vm() {
  log "Suppression de la VM existante $1 (option --forcer)."
  executer VBoxManage unregistervm "$1" --delete
}

# Chemin du disque de la VM de base, seul disque créé explicitement :
# les clones reçoivent leur propre copie de ce disque lors du clonage.
chemin_disque() {
  printf '%s\n' "$RACINE_VM/$1/$1.$EXTENSION_DISQUE"
}

# Configure mémoire, cœurs, vidéo, ordre de démarrage et les deux interfaces
# réseau : NAT pour l'accès Internet et la redirection SSH, réseau privé pour
# le trafic entre les machines du lab.
configurer_materiel() {
  local vm="$1"
  log "Configuration matérielle et réseau de $vm."
  executer VBoxManage modifyvm "$vm" \
    --memory="$MEMOIRE_MO_UTILISEE" \
    --cpus="$NB_CPU_UTILISE" \
    --vram="$VRAM_MO" \
    --boot1=dvd --boot2=disk --boot3=none \
    --nic1="$TYPE_NAT" \
    --nic2="$TYPE_PRIVE" \
    --intnet2="$NOM_RESEAU_INTERNE"
}

# L'image ISO n'est pas toujours transmise au clone : on l'attache explicitement.
attacher_iso() {
  local vm="$1" iso="$2"
  executer_tolerant VBoxManage storageattach "$vm" \
    --storagectl="$NOM_CONTROLEUR" --port=1 --device=0 \
    --type=dvddrive --medium="$iso"
}

# Règle de redirection NAT du port 22 vers le poste hôte.
configurer_redirection_nat() {
  local vm="$1" port="$2"
  # La suppression tolerate l'absence de règle : le premier passage n'en a pas.
  executer_tolerant VBoxManage modifyvm "$vm" --nat-pf1=delete "$NOM_REGLE_NAT"
  # Format de la règle : nom, protocole, adresse du poste, port du poste,
  # adresse de la VM (vide : premier adaptateur) et port dans la VM.
  executer VBoxManage modifyvm "$vm" \
    --nat-pf1="$NOM_REGLE_NAT,tcp,$TAILLE_NAT_HOST,$port,,$PORT_SSH_DANS_VM"
}

creer_vm_base() {
  local vm="$1" iso="$2"
  local dossier disque
  dossier="$RACINE_VM/$vm"
  disque="$(chemin_disque "$vm")"

  log "Création du dossier $dossier."
  mkdir -p "$dossier"
  log "Création du disque $disque (${TAILLE_DISQUE_MO_UTILISEE} Mo)."
  executer VBoxManage createmedium disk --filename="$disque" \
    --size="$TAILLE_DISQUE_MO_UTILISEE" --format="$FORMAT_DISQUE"
  log "Création de la VM de base $vm."
  executer VBoxManage createvm --name "$vm" --ostype "$TYPE_OS" \
    --basefolder "$RACINE_VM" --register
  executer_tolerant VBoxManage storagectl "$vm" --name="$NOM_CONTROLEUR" \
    --add=sata --controller=IntelAhci
  # Disque branché sur le port 0, ISO sur le port 1 : le DVD reste le premier
  # média de démarrage grâce à l'option --boot1 dvd de configurer_materiel.
  executer VBoxManage storageattach "$vm" --storagectl="$NOM_CONTROLEUR" \
    --port=0 --device=0 --type=hdd --medium="$disque"
  attacher_iso "$vm" "$iso"
  configurer_materiel "$vm"
}

cloner_vm() {
  local vm="$1" iso="$2"
  log "Clonage de $NOM_VM_BASE vers $vm (copie complète, indépendante)."
  # --basefolder range le dossier du clone dans le même dossier parent que la
  # VM de base ; le disque est copié par le clonage, il ne doit pas être
  # ré-attaché : le chemin exact du disque copié dépend de la version de
  # VirtualBox et n'a pas à être deviné.
  executer VBoxManage clonevm "$NOM_VM_BASE" --name "$vm" \
    --basefolder "$RACINE_VM" --register
  attacher_iso "$vm" "$iso"
  configurer_materiel "$vm"
}

preparer_vm() {
  local vm="$1" ip="$2" port="$3" iso="$4"
  if vm_deja_presente "$vm"; then
    if [ "$FORCER" = "oui" ]; then
      supprimer_vm "$vm"
    else
      log "VM $vm déjà présente : création ignorée (utiliser --forcer pour la recréer)."
      return 0
    fi
  fi
  if [ "$vm" = "$NOM_VM_BASE" ]; then
    creer_vm_base "$vm" "$iso"
  else
    cloner_vm "$vm" "$iso"
  fi
  configurer_redirection_nat "$vm" "$port"
  log "VM prête : $vm (${ip}, port NAT $port)."
}

# --- Récapitulatif et confirmation -------------------------------------------
afficher_recapitulatif() {
  local i
  printf '\n== Récapitulatif ==\n'
  printf '%-12s %-16s %-18s %s\n' "machine" "adresse privée" "port NAT (SSH)" "action"
  for i in "${!NOMS_VM[@]}"; do
    local action="création"
    if vm_deja_presente "${NOMS_VM[$i]}"; then
      if [ "$FORCER" = "oui" ]; then action="suppression puis recréation"; else action="ignorée (déjà présente)"; fi
    fi
    printf '%-12s %-16s %-18s %s\n' \
      "${NOMS_VM[$i]}" "${IPS_VM[$i]}" "${PORTS_NAT[$i]}" "$action"
  done
  printf '\nImage ISO      : %s\n' "$ISO"
  printf 'Dossier des VM : %s\n' "$RACINE_VM"
  printf 'Mémoire / CPU  : %s Mo / %s cœur(s) par VM\n' "$MEMOIRE_MO_UTILISEE" "$NB_CPU_UTILISE"
  printf 'Disque         : %s Mo par VM\n' "$TAILLE_DISQUE_MO_UTILISEE"
  printf 'Réseau privé   : %s via le réseau interne %s\n' "$RESEAU_PRIVE" "$NOM_RESEAU_INTERNE"
  printf 'Ports NAT      : %s (accès du poste)\n' "${PORTS_NAT[*]}"
  printf '\n'
}

confirmer() {
  local reponse
  if [ "$CONFIRMATION_AUTO" = "oui" ]; then
    log "Confirmation non demandée (option --oui)."
    return 0
  fi
  if [ "$SIMULATION" = "oui" ]; then
    log "Mode simulation : aucune confirmation demandée, aucune commande exécutée."
    return 0
  fi
  printf 'Confirmer la préparation des VM du lab ? (oui/non) : '
  read -r reponse || reponse=""
  case "$reponse" in
    oui|OUI|Oui|o|yes|y) return 0 ;;
    *) avert "Préparation annulée à la demande de l'utilisateur."; exit 0 ;;
  esac
}

# --- Programme principal -----------------------------------------------------
main() {
  analyser_options "$@"
  verifier_outils
  verifier_iso
  afficher_recapitulatif
  confirmer
  verifier_reseau_interne
  local i
  for i in "${!NOMS_VM[@]}"; do
    preparer_vm "${NOMS_VM[$i]}" "${IPS_VM[$i]}" "${PORTS_NAT[$i]}" "$ISO"
  done
  printf '\n'
  succes "Préparation des VM terminée. Démarrer les VM puis, dans chacune d'elles,"
  log "exécuter labs/scripts/10-preparer-vm.sh avec --nom et --ip : web1 directement,"
  log "cn-ansible avec --control-node (reconstruction intégrale uniquement)."
}

main "$@"