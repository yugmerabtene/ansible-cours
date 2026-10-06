# Programme — Ansible : Automatiser la gestion de serveurs

**Auteur : Youghourta Merabtène**

---

## Informations générales

| Champ | Valeur |
|-------|--------|
| **Objet de la formation** | Automatiser la gestion d'un parc de serveurs avec Ansible |
| **Durée totale** | 12 h (2 jours de 6 h) |
| **Horaires** | 9h00-12h00 / 13h00-16h00 |
| **Modalités** | Formation pratique en présentiel, six séquences de 1 h à 3 h, chacune close par un laboratoire sur un environnement isolé |

## Public cible

- Administrateurs systèmes et réseaux
- Ingénieurs DevOps
- Responsables IT souhaitant optimiser la gestion de leurs serveurs

## Prérequis

- Bases en administration Linux
- Aisance avec les commandes Shell et l'édition de fichiers en ligne de commande
- Notions élémentaires sur les réseaux et les systèmes distribués

## Dates

| Jour | Date | Horaires | Durée |
|------|------|----------|-------|
| Jour 1 | 06/10/2026 | 9h00-16h00 | 6 h |
| Jour 2 | 07/10/2026 | 9h00-16h00 | 6 h |

---

## Programme

Les indications ci-dessous représentent les attentes pédagogiques de cette
formation. Le contenu précis de chaque chapitre et l'ordre dans lequel il est
traité peuvent être adaptés selon l'approche et l'expérience du groupe.

### Jour 1 — Architecture, installation et commandes ad hoc

**Présentation d'Ansible et de son architecture (1 heure)**

- Vue d'ensemble des outils d'automatisation disponibles : Ansible, Chef, Puppet
- Fonctionnement sans agent : avantages et limites
- Organisation d'Ansible : modules, tâches, inventaires, rôles
- Laboratoire : explorer une architecture Ansible existante et identifier ses composants

**Installation et configuration d'Ansible (2 heures)**

- Prérequis pour l'installation : distribution Linux supportée, Python, SSH
- Installation et vérification d'Ansible sur une machine de contrôle
- Configuration de l'inventaire et des fichiers de configuration (`ansible.cfg`)
- Laboratoire : installer Ansible et configurer un inventaire statique pour un réseau local

**Introduction aux modules et commandes *ad hoc* (3 heures)**

- Découverte des modules de base : `ping`, `command`, `shell`, `copy`
- Exécution de tâches simples avec les commandes *ad hoc*
- Exploration des paramètres communs des modules Ansible
- Laboratoire : utiliser des modules pour exécuter des tâches simples sur des machines distantes, copier des fichiers et exécuter des commandes distantes avec Ansible

### Jour 2 — Playbooks, rôles et supervision

**Introduction aux playbooks Ansible (2 heures)**

- Syntaxe YAML pour les playbooks
- Structure d'un playbook : hôtes, tâches, handlers
- Gestion des variables et des conditions
- Laboratoire : créer un playbook pour déployer un service web basique, utiliser des variables et des conditions dans un playbook

**Gestion avancée des rôles et des variables (2 heures)**

- Introduction aux rôles : organisation des tâches et des fichiers
- Définir des variables globales et locales
- Hiérarchisation et utilisation des fichiers `group_vars` et `host_vars`
- Laboratoire : organiser un projet Ansible en utilisant des rôles et des variables

**Supervision et gestion d'une infrastructure (2 heures)**

- Débogage et gestion des erreurs dans Ansible
- Utilisation des stratégies d'exécution et des *forks*
- Surveillance et *reporting* des tâches exécutées
- Laboratoire : exécuter un playbook complexe avec plusieurs rôles et superviser les résultats
