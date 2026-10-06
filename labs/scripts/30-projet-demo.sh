#!/usr/bin/env bash
# ===========================================================================
# 30-projet-demo.sh — Création du projet Ansible de démonstration du lab
#
# Où l'exécuter : sur le CONTROL NODE du lab, avec les droits root :
#   sudo labs/scripts/30-projet-demo.sh
#
# Ce que fait le script :
#   1. crée le projet de démonstration /opt/ansible-demo, en lecture seule pour
#      le compte stagiaire : inventaire statique (groupe webservers, hôte
#      web1), ansible.cfg, variables de groupe, quatre playbooks de
#      démonstration et un gabarit Jinja2 ;
#   2. crée le squelette du projet du cours ~/ansible-lab, appartenant au
#      compte stagiaire : playbooks/, playbooks/templates/, roles/,
#      group_vars/, host_vars/ ;
#   3. contrôle, si Ansible est installé, la syntaxe des playbooks et la
#      cohérence de l'inventaire.
#
# Idempotence : chaque fichier n'est écrit que si son contenu change ; un
# second passage annonce les fichiers inchangés et ne touche à rien.
#
# Sécurité : aucun secret n'est écrit dans ces fichiers. Le compte de
# connexion (stagiaire) et l'adresse des nodes viennent du contrat du lab.
# ===========================================================================
set -euo pipefail

# --- Contrats du lab ---------------------------------------------------------
readonly RACINE_DEMO="/opt/ansible-demo"   # projet de démonstration lu par le formateur
readonly UTILISATEUR_LAB="stagiaire"       # compte créé par 10-preparer-vm.sh
readonly DOSSIER_PROJET="/home/${UTILISATEUR_LAB}/ansible-lab"  # squelette du projet du cours
readonly ADRESSE_WEB1="172.16.0.11"        # web1 : seul node managé du lab
readonly DROITS_REPERTOIRE="755"           # répertoires lisibles par le compte stagiaire
readonly DROITS_FICHIER="644"              # fichiers lisibles, non modifiables par le compte

# --- Valeurs par défaut (modifiables par les options de la ligne de commande) -
RACINE_DEMO_CHOISIE="$RACINE_DEMO"
DOSSIER_PROJET_CHOISIE="$DOSSIER_PROJET"
CREER_PROJET="oui"      # créer le squelette du projet du cours (option --sans-projet)
CONTROLE_SYNTAXE="oui"  # contrôler les playbooks si Ansible est présent
SIMULATION="non"        # afficher les actions sans les exécuter

# --- Fichiers temporaires ----------------------------------------------------
FICHIER_TEMPORAIRE=""

nettoyer() {
  if [ -n "$FICHIER_TEMPORAIRE" ]; then
    rm -f -- "$FICHIER_TEMPORAIRE"
  fi
}
trap nettoyer EXIT

# --- Fonctions de trace ------------------------------------------------------
log()    { printf '[INFO] %s\n' "$*"; }
succes() { printf '[OK] %s\n' "$*"; }
avert()  { printf '[AVERTISSEMENT] %s\n' "$*" >&2; }
erreur() { printf '[ERREUR] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'AIDE'
Utilisation : 30-projet-demo.sh [options]

Crée le projet Ansible de démonstration (/opt/ansible-demo) et le squelette du
projet du cours (~/ansible-lab). À exécuter avec les droits root sur le
control node du lab.

Options :
  --racine-demo <chemin>  Répertoire du projet de démonstration.
                          Valeur par défaut : /opt/ansible-demo
  --projet <chemin>       Répertoire du squelette du projet du cours.
                          Valeur par défaut : /home/stagiaire/ansible-lab
  --sans-projet           Ne pas créer le squelette ~/ansible-lab.
  --sans-controle         Ne pas contrôler la syntaxe des playbooks, même
                          si Ansible est installé.
  --simulation            Afficher les actions sans les exécuter.
  -h, --aide, --help      Afficher cette aide.

Contenu créé dans le projet de démonstration :
  inventory.yml            groupe webservers (hôte web1)
  ansible.cfg              configuration du control node (section [defaults])
  group_vars/all.yml       variables communes
  group_vars/webservers.yml  variables du groupe webservers
  playbooks/verifier-connexion.yml  test de connectivité (module ping)
  playbooks/verifier-os.yml        relevé de la distribution des nodes
  playbooks/installer-paquet.yml   installation idempotente d'un paquet
  playbooks/deployer-accueil.yml   déploiement d'un gabarit Jinja2
  playbooks/templates/index.html.j2  gabarit de la page d'accueil
  README.md                présentation du projet

Vérification manuelle possible ensuite :
  cd /opt/ansible-demo
  ansible-inventory --graph
  ansible all -m ping
  ansible-playbook playbooks/verifier-connexion.yml
AIDE
}

analyser_options() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--aide|--help) usage; exit 0 ;;
      --racine-demo)    RACINE_DEMO_CHOISIE="${2:?chemin manquant pour --racine-demo}"; shift 2 ;;
      --racine-demo=*)  RACINE_DEMO_CHOISIE="${1#*=}"; shift ;;
      --projet)         DOSSIER_PROJET_CHOISIE="${2:?chemin manquant pour --projet}"; shift 2 ;;
      --projet=*)       DOSSIER_PROJET_CHOISIE="${1#*=}"; shift ;;
      --sans-projet)    CREER_PROJET="non"; shift ;;
      --sans-controle)  CONTROLE_SYNTAXE="non"; shift ;;
      --simulation)     SIMULATION="oui"; shift ;;
      "")               erreur "argument vide ; utiliser --aide pour la liste des options" ;;
      *)                erreur "option inconnue : $1 (utiliser --aide)" ;;
    esac
  done
}

exiger_root() {
  [ "$(id -u)" -eq 0 ] || erreur "ce script doit être exécuté avec les droits root : sudo $0 $*"
}

# --- Écriture idempotente ----------------------------------------------------
creer_repertoire() {
  local chemin="$1"
  if [ -d "$chemin" ]; then
    log "répertoire présent : $chemin"
    return 0
  fi
  log "création du répertoire $chemin"
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] mkdir -p -m %s %s\n' "$DROITS_REPERTOIRE" "$chemin"
    return 0
  fi
  mkdir -p "$chemin"
  chmod "$DROITS_REPERTOIRE" "$chemin"
}

# Écrit un fichier lu sur l'entrée standard, seulement si son contenu change.
ecrire_si_different() {
  local cible="$1" droits="$2"
  FICHIER_TEMPORAIRE="$(mktemp)"
  cat > "$FICHIER_TEMPORAIRE"
  if [ -f "$cible" ] && cmp -s "$FICHIER_TEMPORAIRE" "$cible"; then
    log "inchangé : $cible"
    return 0
  fi
  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] écriture de %s (droits %s)\n' "$cible" "$droits"
    return 0
  fi
  install -D -m "$droits" "$FICHIER_TEMPORAIRE" "$cible"
  succes "écrit : $cible"
}

# --- Contenu du projet de démonstration -------------------------------------
# Seul heredoc non cité du script : les adresses proviennent des constantes
# définies en tête, il n'existe donc qu'une source de vérité pour le
# contrat d'adressage du lab.
ecrire_inventaire() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/inventory.yml" "$DROITS_FICHIER" <<FIN_INVENTAIRE
# Inventaire statique du projet de démonstration du lab Ansible.
# Syntaxe YAML : all > children > groupes > hosts.
# ansible_host indique l'adresse de connexion, ansible_user le compte SSH.
all:
  vars:
    ansible_user: stagiaire
    ansible_python_interpreter: /usr/bin/python3
  children:
    webservers:
      hosts:
        web1:
          ansible_host: ${ADRESSE_WEB1}
FIN_INVENTAIRE
}

ecrire_configuration() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/ansible.cfg" "$DROITS_FICHIER" <<'FIN_CONFIGURATION'
# Configuration du control node du lab, limitée à ce projet.
# Ansible utilise le premier fichier trouvé : ANSIBLE_CONFIG, puis
# ansible.cfg du répertoire courant, puis ~/.ansible.cfg, puis /etc/ansible.
[defaults]
inventory = ./inventory.yml
remote_user = stagiaire
forks = 5
host_key_checking = False
interpreter_python = auto
inject_facts_as_vars = False
timeout = 10
FIN_CONFIGURATION
}

ecrire_variables_communes() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/group_vars/all.yml" "$DROITS_FICHIER" <<'FIN_VARIABLES_ALL'
# Variables communes à toutes les machines du lab.
# Ce fichier est adjacent à l'inventaire : Ansible le charge automatiquement.
# Les faits sont injectés dans ansible_facts : y accéder par
# ansible_facts['cle'], jamais par une variable de premier niveau.
repertoire_accueil: /var/www/html
fichier_accueil: /var/www/html/index.html
FIN_VARIABLES_ALL

  ecrire_si_different "$RACINE_DEMO_CHOISIE/group_vars/webservers.yml" "$DROITS_FICHIER" <<'FIN_VARIABLES_WEB'
# Variables du groupe webservers : elles priment sur group_vars/all.yml.
paquet_web: nginx
FIN_VARIABLES_WEB
}

ecrire_playbooks() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/playbooks/verifier-connexion.yml" "$DROITS_FICHIER" <<'FIN_PLAYBOOK_PING'
---
# Playbook de démonstration : prouver que le control node atteint tous les
# nodes sans agent installé. Le module ping utilise le canal SSH.
- name: Vérifier la connectivité avec tous les nodes du lab
  hosts: all
  gather_facts: false
  tasks:
    - name: Envoyer un ping Ansible à chaque node
      ansible.builtin.ping:
FIN_PLAYBOOK_PING

  ecrire_si_different "$RACINE_DEMO_CHOISIE/playbooks/verifier-os.yml" "$DROITS_FICHIER" <<'FIN_PLAYBOOK_OS'
---
# Playbook de démonstration : collecter les faits puis les afficher.
# Avec inject_facts_as_vars = False dans ansible.cfg, les faits se lisent
# par ansible_facts['cle'].
- name: Relever la distribution et la version de Python des nodes
  hosts: all
  gather_facts: true
  tasks:
    - name: Afficher la distribution détectée sur chaque node
      ansible.builtin.debug:
        msg: >-
          {{ inventory_hostname }} :
          {{ ansible_facts['distribution'] }} {{ ansible_facts['distribution_version'] }},
          Python {{ ansible_facts['python_version'] }}
FIN_PLAYBOOK_OS

  ecrire_si_different "$RACINE_DEMO_CHOISIE/playbooks/installer-paquet.yml" "$DROITS_FICHIER" <<'FIN_PLAYBOOK_PAQUET'
---
# Playbook de démonstration : installation idempotente d'un paquet.
# state: present (et non latest) évite une modification à chaque exécution ;
# update_cache: true rafraîchit la liste des paquets avant installation.
- name: Installer le serveur web sur le groupe webservers
  hosts: webservers
  become: true
  gather_facts: false
  tasks:
    - name: Installer le paquet défini dans group_vars/webservers.yml
      ansible.builtin.apt:
        name: "{{ paquet_web }}"
        state: present
        update_cache: true
        cache_valid_time: 3600
FIN_PLAYBOOK_PAQUET

  ecrire_si_different "$RACINE_DEMO_CHOISIE/playbooks/deployer-accueil.yml" "$DROITS_FICHIER" <<'FIN_PLAYBOOK_ACCUEIL'
---
# Playbook de démonstration : déployer un fichier depuis un gabarit Jinja2.
# src est cherché dans le sous-répertoire templates du playbook, soit
# playbooks/templates/index.html.j2. Un second passage ne produit aucun
# changement : le module compare le fichier rendu au fichier présent.
- name: Déployer la page d'accueil sur le groupe webservers
  hosts: webservers
  become: true
  gather_facts: true
  tasks:
    - name: Créer le répertoire de la page d'accueil
      ansible.builtin.file:
        path: "{{ repertoire_accueil }}"
        state: directory
        owner: root
        group: root
        mode: "0755"

    - name: Déployer la page d'accueil depuis le gabarit
      ansible.builtin.template:
        src: index.html.j2
        dest: "{{ fichier_accueil }}"
        owner: root
        group: root
        mode: "0644"
FIN_PLAYBOOK_ACCUEIL
}

ecrire_gabarit() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/playbooks/templates/index.html.j2" "$DROITS_FICHIER" <<'FIN_GABARIT'
<!DOCTYPE html>
<html lang="fr">
  <head>
    <meta charset="utf-8">
    <title>Lab Ansible</title>
  </head>
  <body>
    <h1>Lab Ansible</h1>
    <p>Machine : {{ inventory_hostname }}</p>
    <p>Groupe : {{ group_names | join(', ') }}</p>
    <p>Adresse : {{ ansible_facts['default_ipv4']['address'] }}</p>
    <p>Fichier généré par Ansible le {{ ansible_facts['date_time']['iso8601'] }}.</p>
  </body>
</html>
FIN_GABARIT
}

ecrire_readme() {
  ecrire_si_different "$RACINE_DEMO_CHOISIE/README.md" "$DROITS_FICHIER" <<'FIN_README'
# Projet de démonstration Ansible

Projet de lecture fourni avec le lab, utilisé pour découvrir l'architecture
control node / nodes managés avant les exercices.

## Contenu

| Chemin | Rôle |
|--------|------|
| `inventory.yml` | Liste des nodes : groupe `webservers` (hôte `web1`) |
| `ansible.cfg` | Configuration du control node (section `[defaults]`) |
| `group_vars/all.yml` | Variables communes à toutes les machines |
| `group_vars/webservers.yml` | Variables du groupe `webservers` |
| `playbooks/verifier-connexion.yml` | Test de connectivité avec le module `ansible.builtin.ping` |
| `playbooks/verifier-os.yml` | Collecte et affichage des faits (distribution, Python) |
| `playbooks/installer-paquet.yml` | Installation idempotente d'un paquet (`state: present`) |
| `playbooks/deployer-accueil.yml` | Déploiement d'un gabarit Jinja2 sur `web1` |
| `playbooks/templates/index.html.j2` | Gabarit de la page d'accueil |

## Utilisation

Depuis ce répertoire :

```bash
ansible-inventory --graph
ansible all -m ping
ansible-playbook playbooks/verifier-connexion.yml
ansible-playbook playbooks/deployer-accueil.yml
```

Les playbooks sont idempotents : une seconde exécution ne doit produire
aucun changement, seulement des tâches rapportées `ok`.
FIN_README
}

creer_projet_demo() {
  log "Création du projet de démonstration $RACINE_DEMO_CHOISIE."
  creer_repertoire "$RACINE_DEMO_CHOISIE"
  creer_repertoire "$RACINE_DEMO_CHOISIE/group_vars"
  creer_repertoire "$RACINE_DEMO_CHOISIE/playbooks"
  creer_repertoire "$RACINE_DEMO_CHOISIE/playbooks/templates"
  ecrire_inventaire
  ecrire_configuration
  ecrire_variables_communes
  ecrire_playbooks
  ecrire_gabarit
  ecrire_readme
}

# --- Squelette du projet du cours -------------------------------------------
creer_projet_cours() {
  if [ "$CREER_PROJET" = "non" ]; then
    log "squelette du projet du cours ignoré (option --sans-projet)."
    return 0
  fi
  log "Création du squelette du projet du cours $DOSSIER_PROJET_CHOISIE."
  creer_repertoire "$DOSSIER_PROJET_CHOISIE"
  creer_repertoire "$DOSSIER_PROJET_CHOISIE/playbooks"
  creer_repertoire "$DOSSIER_PROJET_CHOISIE/playbooks/templates"
  creer_repertoire "$DOSSIER_PROJET_CHOISIE/roles"
  creer_repertoire "$DOSSIER_PROJET_CHOISIE/group_vars"
  creer_repertoire "$DOSSIER_PROJET_CHOISIE/host_vars"

  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] chown -R %s %s\n' "$UTILISATEUR_LAB" "$DOSSIER_PROJET_CHOISIE"
    return 0
  fi
  # Le projet du cours appartient au compte stagiaire : il doit pouvoir y
  # écrire ses playbooks et ses variables.
  if id -u "$UTILISATEUR_LAB" >/dev/null 2>&1; then
    chown -R "$UTILISATEUR_LAB:$UTILISATEUR_LAB" "$DOSSIER_PROJET_CHOISIE"
    succes "propriétaire du projet du cours : $UTILISATEUR_LAB"
  else
    avert "compte $UTILISATEUR_LAB absent : exécuter 10-preparer-vm.sh sur le"
    avert "control node avant, ou corriger le propriétaire de $DOSSIER_PROJET_CHOISIE."
  fi
}

# --- Contrôle final ----------------------------------------------------------
controler_projet() {
  if [ "$CONTROLE_SYNTAXE" = "non" ]; then
    log "contrôle de syntaxe ignoré (option --sans-controle)."
    return 0
  fi
  if ! command -v ansible-playbook >/dev/null 2>&1; then
    avert "ansible-playbook introuvable : contrôle de syntaxe impossible."
    avert "Installer Ansible sur le control node puis relancer ce script."
    return 0
  fi

  local fichier echecs=0
  log "Contrôle de la syntaxe des playbooks depuis $RACINE_DEMO_CHOISIE."
  for fichier in "$RACINE_DEMO_CHOISIE"/playbooks/*.yml; do
    [ -e "$fichier" ] || continue
    if [ "$SIMULATION" = "oui" ]; then
      printf '    [simulation] ansible-playbook %s --syntax-check\n' "$fichier"
      continue
    fi
    if ( ( cd "$RACINE_DEMO_CHOISIE" && ansible-playbook "playbooks/$(basename "$fichier")" --syntax-check ) >/dev/null 2>&1 ); then
      succes "syntaxe valide : $(basename "$fichier")"
    else
      avert "syntaxe invalide : $(basename "$fichier")"
      echecs=$((echecs + 1))
    fi
  done

  if [ "$SIMULATION" = "oui" ]; then
    printf '    [simulation] ansible-inventory --list\n'
    return 0
  fi
  if ( ( cd "$RACINE_DEMO_CHOISIE" && ansible-inventory --list ) >/dev/null 2>&1 ); then
    succes "inventaire lisible par Ansible."
  else
    avert "inventaire illisible par Ansible."
    echecs=$((echecs + 1))
  fi

  if [ "$echecs" -gt 0 ]; then
    erreur "$echecs contrôle(s) en échec sur le projet de démonstration."
  fi
}

main() {
  analyser_options "$@"
  exiger_root "$@"

  printf '\n== Récapitulatif ==\n'
  printf 'Projet de démonstration : %s\n' "$RACINE_DEMO_CHOISIE"
  printf 'Squelette du projet      : %s\n' "$DOSSIER_PROJET_CHOISIE"
  printf 'Compte propriétaire      : %s\n' "$UTILISATEUR_LAB"
  printf '\n'

  creer_projet_demo
  creer_projet_cours
  controler_projet

  printf '\n'
  succes "Projets Ansible créés."
  log "Découvrir le projet : cd $RACINE_DEMO_CHOISIE && ansible-inventory --graph"
  log "Contrôler le lab : labs/scripts/90-verifier-lab.sh"
}

main "$@"