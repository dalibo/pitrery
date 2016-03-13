Pitrery: Outil de sauvegarde-restauration Point-In-Time Recovery (PITR)  pour PostgreSQL
========================================================================================


FONCTIONNALITES
---------------

pitrery est un ensemble d'outils permettant de faciliter la gestion des 
sauvegardes et restaurations PITR (récupération à un instant donné) : 

- Gestion de l'archivage des segments WAL, prise en charge de la compression, 
  en local ou vers un serveur cible joignable par SSH 

- Automatisation du basebackup

- Restauration à une date donnée

- Gestion de la rétention des sauvegardes.


INSTALLATION RAPIDE
-------------------

1. Récupérer les sources

2. Modifier le fichier `config.mk`

3. Lancer `make` et `make install`

4. Lancer `pitrery configure -o pitr -f [[user@]host:]/path/to/backups` (user@host étant optionnel)

5. Configurer l'archivage (`archive_command = 'archive_xlog -C pitr %p'`)

6. Lancer `pitrery` pour réaliser vos sauvegardes et restaurations.


DEVELOPPEMENT
-------------

Le code source est disponible sur github: https://github.com/dalibo/pitrery

pitrery est developpé par Nicolas Thauvin sous licence BSD classique à 2 
clauses. Référez-vous à la partie licence dans les scripts ou au fichier 
COPYRIGHT.

