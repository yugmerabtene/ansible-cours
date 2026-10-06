#!/usr/bin/env bash
# ===========================================================================
# 90-verifier-lab.sh — Contrôle complet du lab Ansible
#
# Où l'exécuter : sur le CONTROL NODE du lab, après 10-preparer-vm.sh,
# 20-cle-ssh.sh et 30-projet-demo.sh.
#
# Contrôles effectués, machine par machine (cn-ansible puis web1) :
#   1. identité      : le nom d'hôte retourné par SSH est bien celui attendu ;
#   2. adressage     : la machine porte l'adresse fixe du contrat du lab ;
#   3. résolution    : le nom se résout vers la bonne adresse (entrées
#                      /etc/hosts écrites par 10-preparer-vm.sh) ;
#   4. SSH           : connexion sans mot de passe possible en mode non
#                      interactif (BatchMode) ;
#   5. Ansible       : ansible all -m ping renvoie pong pour les nodes de
#                      l'inventaire (module ping, aucun agent sur les nodes).
#
# Contrôles globaux : présence des commandes Ansible, lisibilité de
# l'inventaire, vue graphique de sa structure (ansible-inventory --graph,
# groupe webservers attendu et aucun groupe inattendu).
#
# Code de sortie : 0 si tous les contrôles passent, 1 sinon. Le récapitulatif
# final liste chaque machine et chaque contrôle.
# ===========================================================================
set -euo pipefail

# --- Contrat d'adressage du lab ---------------------------------------------
readonly -a NOMS_VM=("cn-ansible" "web1")
readonly -a IPS_VM=("172.16.0.10" "172.16.0.11")
readonly MASQUE_LAB=24             # préfixe du réseau privé
readonly UTILISATEUR="stagiaire"   # compte SSH utilisé par Ansible
readonly DELAI_CONNEXION=10        # secondes accordées à une connexion SSH

# --- Projet Ansible utilisé pour les contrôles Ansible ------------------------
readonly PROJET_PAR_DEFAUT="/opt/ansible-demo"  # projet de démonstration du lab
readonly NB_NODES_ATTENDUS=1      # seul node de l'inventaire de démonstration :
                                  # web1 (le control node n'en fait pas partie)

# --- Valeurs par défaut (modifiables par les options de la ligne de commande) -
PROJET="$PROJET_PAR_DEFAUT"
CHEMIN_CLE="${HOME}/.ssh/id_ed25519"  # clé privée utilisée pour les tests SSH
CONTROLE_ANSIBLE="oui"  # effectuer les contrôles Ansible (option --sans-ansible)
SIMULATION="non"        # afficher les commandes sans les exécuter

# --- Résultats des contrôles -------------------------------------------------
declare -a RESULTATS_NOMS=()
declare -a RESULTATS_HOTES=()
declare -a RESULTATS_ETATS=()

ECHECS=0

# --- Fonctions de trace ------------------------------------------------------
log()     { printf '[INFO] %s\n' "$*"; }
succes()  { printf '[OK] %s\n' "$*"; }
avert()   { printf '[AVERTISSEMENT] %s\n' "$*" >&2; }
erreur()  { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'AIDE'
Utilisation : 90-verifier-lab.sh [options]

Contrôle l'état du lab Ansible : identités, adresses IP, résolution de noms,
accès SSH sans mot de passe, module ping et vue graphique de l'inventaire.
À exécuter sur le control node du lab.

Options :
  --projet <chemin>    Projet Ansible à contrôler.
                       Valeur par défaut : /opt/ansible-demo
  --identite <fichier> Clé privée utilisée pour les tests SSH.
                       Valeur par défaut : ~/.ssh/id_ed25519
  --sans-ansible       Ne pas lancer les commandes Ansible (utile avant leur
                       installation) : seuls les contrôles système sont faits.
  --simulation         Afficher les commandes sans les exécuter.
  -h, --aide, --help   Afficher cette aide.

Adresses contrôlées :
  cn-ansible 172.16.0.10, web1 172.16.0.11

Code de sortie : 0 si tous les contrôles passent, 1 sinon.
AIDE
}

analyser_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--aide|--help)  usage; exit 0 ;;
      --projet)          PROJET="${2:?chemin manquant pour --projet}"; shift 2 ;;
      --projet=*)        PROJET="${1#*=}"; shift ;;
      --identite)        CHEMIN_CLE="${2:?chemin manquant pour --identite}"; shift 2 ;;
      --identite=*)      CHEMIN_CLE="${1#*=}"; shift ;;
      --sans-ansible)    CONTROLE_ANSIBLE="non"; shift ;;
      --simulation)      SIMULATION="oui"; shift ;;
      "")                erreur "argument vide ; utiliser --aide pour la liste des options" ;;
      *)                 erreur "option inconnue : $1 (utiliser --aide)" ;;
    esac
  done
}

# Mémorise le résultat d'un contrôle pour le récapitulatif final.
enregistrer() {
  local nom="$1" libelle="$2" etat="$3"
  RESULTATS_NOMS+=("$nom")
  RESULTATS_HOTES+=("$libelle")
  RESULTATS_ETATS+=("$etat")
  if [ "$etat" = "OK" ]; then
    succes "$nom — $libelle"
  else
    ECHECS=$((ECHECS + 1))
    printf '[ECHEC] %s — %s\n' "$nom" "$libelle" >&2
  fi
}

# --- Exécution d'une commande distante sur un node du lab -------------------
sur_node() {
  local index="$1" commande="$2"
  ssh \
    -i "$CHEMIN_CLE" \
    -o BatchMode=yes \
    -o "ConnectTimeout=$DELAI_CONNEXION" \
    -o StrictHostKeyChecking=accept-new \
    "$UTILISATEUR@${IPS_VM[$index]}" "$commande" 2>/dev/null
}

# --- Contrôle 1 : accès SSH sans mot de passe -------------------------------
controler_ssh() {
  local index="$1" nom="${NOMS_VM[$1]}" sortie
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] ssh -o BatchMode=yes %s@%s true\n' "$UTILISATEUR" "${IPS_VM[$index]}"
    enregistrer "$nom" "accès SSH" "OK"
    return 0
  fi
  if sortie="$(sur_node "$index" 'true')"; then
    enregistrer "$nom" "accès SSH sans mot de passe" "OK"
    return 0
  fi
  enregistrer "$nom" "accès SSH sans mot de passe (échec)" "KO"
  return 1
}

# --- Contrôle 2 : identité de la machine ------------------------------------
controler_identite() {
  local index="$1" nom="${NOMS_VM[$1]}" attendu="${NOMS_VM[$1]}" obtenu
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] ssh %s@%s hostname -s\n' "$UTILISATEUR" "${IPS_VM[$index]}"
    enregistrer "$nom" "identité ($attendu)" "OK"
    return 0
  fi
  if ! obtenu="$(sur_node "$index" 'hostname -s')"; then
    enregistrer "$nom" "identité (machine injoignable)" "KO"
    return 1
  fi
  if [ "$obtenu" = "$attendu" ]; then
    enregistrer "$nom" "identité ($obtenu)" "OK"
    return 0
  fi
  enregistrer "$nom" "identité ($obtenu au lieu de $attendu)" "KO"
  return 1
}

# --- Contrôle 3 : adresse IP fixe du contrat --------------------------------
controler_adresse() {
  local index="$1" nom="${NOMS_VM[$1]}" adresse="${IPS_VM[$1]}" adresses
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] ssh %s@%s ip -br -4 addr\n' "$UTILISATEUR" "${IPS_VM[$index]}"
    enregistrer "$nom" "adresse $adresse/$MASQUE_LAB" "OK"
    return 0
  fi
  if ! adresses="$(sur_node "$index" 'ip -br -4 addr')"; then
    enregistrer "$nom" "adresse $adresse (machine injoignable)" "KO"
    return 1
  fi
  if printf '%s\n' "$adresses" | grep -q "$adresse/$MASQUE_LAB"; then
    enregistrer "$nom" "adresse $adresse/$MASQUE_LAB" "OK"
    return 0
  fi
  enregistrer "$nom" "adresse $adresse/$MASQUE_LAB absente" "KO"
  return 1
}

# --- Contrôle 4 : résolution de noms ----------------------------------------
controler_resolution() {
  local index="$1" nom="${NOMS_VM[$1]}" adresse="${IPS_VM[$1]}" resultat
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] getent hosts %s\n' "$nom"
    enregistrer "$nom" "résolution de $nom" "OK"
    return 0
  fi
  if ! resultat="$(getent hosts "$nom")"; then
    enregistrer "$nom" "résolution de $nom (nom introuvable)" "KO"
    return 1
  fi
  if printf '%s\n' "$resultat" | grep -q "$adresse"; then
    enregistrer "$nom" "résolution de $nom vers $adresse" "OK"
    return 0
  fi
  enregistrer "$nom" "résolution de $nom vers une autre adresse" "KO"
  return 1
}

# --- Contrôle 5 : module ping d Ansible -------------------------------------
controler_ping_ansible() {
  local sortie nb_pong attendus

  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] cd %s && ansible all -m ping\n' "$PROJET"
    enregistrer "inventaire" "ansible all -m ping" "OK"
    return 0
  fi

  if ! command -v ansible >/dev/null 2>&1; then
    enregistrer "inventaire" "commande ansible absente du control node" "KO"
    return 1
  fi
  if ! sortie="$( ( cd "$PROJET" && ansible all -m ping ) 2>&1 )"; then
    printf '%s\n' "$sortie" >&2
    enregistrer "inventaire" "ansible all -m ping (échec d'exécution)" "KO"
    return 1
  fi

  nb_pong="$(printf '%s\n' "$sortie" | grep -c 'pong' || true)"
  attendus="$(compter_noeuds_inventaire || true)"
  [ -n "$attendus" ] || attendus="$NB_NODES_ATTENDUS"

  if [ "$nb_pong" -ge "$attendus" ]; then
    enregistrer "inventaire" "ansible all -m ping ($nb_pong réponse(s) pong)" "OK"
    return 0
  fi
  enregistrer "inventaire" "ansible all -m ping ($nb_pong pong pour $attendus attendus)" "KO"
  return 1
}

# Nombre de nœuds déclarés dans l'inventaire du projet.
compter_noeuds_inventaire() {
  ( ( cd "$PROJET" && ansible-inventory --list ) 2>/dev/null ) | grep -c '"ansible_host":'
}

# --- Contrôle global : vue graphique de l'inventaire ------------------------
# La vue graphique doit contenir le groupe webservers, aucun autre groupe de
# l'inventaire et un seul hôte : le lab ne compte qu'un node managé.
# @all est la racine et @ungrouped un groupe interne à Ansible (hôtes non
# rattachés à un groupe) : aucun des deux n'est un groupe de l'inventaire.
controler_inventaire_graphique() {
  local sortie autres_groupes nb_hotes
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] cd %s && ansible-inventory --graph\n' "$PROJET"
    enregistrer "inventaire" "ansible-inventory --graph (@all, webservers, 1 hôte)" "OK"
    return 0
  fi
  if ! sortie="$( ( cd "$PROJET" && ansible-inventory --graph ) 2>&1 )"; then
    printf '%s\n' "$sortie" >&2
    enregistrer "inventaire" "ansible-inventory --graph (échec)" "KO"
    return 1
  fi
  if ! printf '%s\n' "$sortie" | grep -q '@webservers:'; then
    printf '%s\n' "$sortie" >&2
    enregistrer "inventaire" "ansible-inventory --graph (groupe webservers absent)" "KO"
    return 1
  fi
  autres_groupes="$(printf '%s\n' "$sortie" \
    | sed -n 's/^[[:space:]]*|--@\([^:]*\):.*/\1/p' \
    | grep -v -e '^webservers$' -e '^ungrouped$' || true)"
  if [ -n "$autres_groupes" ]; then
    printf '%s\n' "$sortie" >&2
    enregistrer "inventaire" "ansible-inventory --graph (groupe(s) inattendu(s) : $(printf '%s' "$autres_groupes" | tr '\n' ' '))" "KO"
    return 1
  fi
  # Lignes « | … --nom » : hôtes des groupes. Les groupes sont toujours
  # affichés avec un « @ » devant leur nom, d'où le filtre [^@].
  nb_hotes="$(printf '%s\n' "$sortie" | grep -cE '^[[:space:]]*\|.*--[^@]' || true)"
  if [ "$nb_hotes" -ne 1 ]; then
    printf '%s\n' "$sortie" >&2
    enregistrer "inventaire" "ansible-inventory --graph ($nb_hotes hôte(s) au lieu de 1)" "KO"
    return 1
  fi
  printf '%s\n' "$sortie"
  enregistrer "inventaire" "ansible-inventory --graph (@all, webservers, 1 hôte)" "OK"
  return 0
}

# --- Récapitulatif -----------------------------------------------------------
afficher_recapitulatif() {
  local i
  printf '\n== Récapitulatif des contrôles ==\n'
  printf '%-12s %-46s %s\n' "machine" "contrôle" "état"
  for i in "${!RESULTATS_NOMS[@]}"; do
    printf '%-12s %-46s %s\n' \
      "${RESULTATS_NOMS[$i]}" "${RESULTATS_HOTES[$i]}" "${RESULTATS_ETATS[$i]}"
  done
  printf '\nContrôles effectués : %d, échecs : %d\n' "${#RESULTATS_NOMS[@]}" "$ECHECS"
}

main() {
  analyser_options "$@"

  printf '\n== Paramètres ==\n'
  printf 'Projet Ansible    : %s\n' "$PROJET"
  printf 'Clé SSH           : %s\n' "$CHEMIN_CLE"
  printf 'Contrôles Ansible : %s\n' "$CONTROLE_ANSIBLE"
  printf '\n'

  if [ "$CONTROLE_ANSIBLE" = "oui" ] && [ "$SIMULATION" = "non" ] && [ ! -d "$PROJET" ]; then
    avert "projet Ansible introuvable : $PROJET (utiliser --projet pour le corriger)."
  fi

  printf '== Contrôles système ==\n'
  local i
  for i in "${!NOMS_VM[@]}"; do
    controler_ssh "$i" || true
    controler_identite "$i" || true
    controler_adresse "$i" || true
    controler_resolution "$i" || true
  done

  if [ "$CONTROLE_ANSIBLE" = "oui" ]; then
    printf '\n== Contrôles Ansible ==\n'
    controler_inventaire_graphique || true
    controler_ping_ansible || true
  else
    log "contrôles Ansible ignorés (option --sans-ansible)."
  fi

  afficher_recapitulatif

  printf '\n'
  if [ "$ECHECS" -eq 0 ]; then
    succes "Lab conforme : tous les contrôles passent."
    exit 0
  fi
  printf '[ECHEC] %d contrôle(s) en échec : revoir les étapes de préparation.\n' "$ECHECS" >&2
  exit 1
}

main "$@"