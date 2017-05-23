Mise à jour 1.13
================

Rien à faire.


Mise à jour 1.12
================

Assurez vous d'utiliser les nouveaux nom de paramètres de compression
pour l'archivage, introduits en 1.9. Les anciens ne sont plus supportés.


Mise à jour 1.11
================

Rien à faire.


Mise à jour 1.10
================

Rien à faire.


Mise à jour 1.9
================

Archivages des fichiers WAL et restauration
--------------------------------------------

Les paramètres de configuration suivants ont été renommés :

* `COMPRESS_BIN` -> `ARCHIVE_COMPRESS_BIN`
* `COMPRESS_SUFFIX` -> `ARCHIVE_COMPRESS_SUFFIX`
* `UNCOMPRESS_BIN` -> `ARCHIVE_UNCOMPRESS_BIN`

La méthode la plus fiable pour mettre à jour votre fichier de 
configuration sur un système en production est la suivante :

- Ajouter les nouveaux paramètres au fichier de configuration sans 
  toucher aux anciens
- Faire la mise à jour
- Retirer les paramètres obsolètes du fichier de configuration


Restauration
------------

Si les paramètres utilisés sont différents de ceux définis dans le 
fichier de configuration, les options pour restore_xlog doivent être 
ajoutées en utilisant une commande de restauration personnalisée avec
l'option `-r` 


Mise à jour 1.8
===============

Sauvegarde
----------

En utilisant la méthode "rsync", l'arborescence de la précédente 
sauvegarde est dupliquée en utilisant des pointeurs (hardlinks) avant de 
réellement resynchroniser la nouvelle arborescence.
La duplication peut être réalisée avec `cp -rl` ou `pax -rwl`. 
Cela permet à pitrery d'avoir une meilleure portabilité vers des systèmes
non-GNU.
L'outil peut être choisi à la compilation, GNU cp restant la méthode par 
défaut.

En utilisant cette méthode avec SSH, `pax` peut être nécessaire sur le 
serveur cible.


Mise à jour 1.7
===============

Utilisation
-----------

* Lancer pitrery en utilisant `pitr_mgr` n'est plus possible.
  Le lien symbolique a été supprimé après 2 versions de rétro-compatibilité.

* Le script additionnel (hook) post-sauvegarde, paramétrable grâce à 
  `POST_BACKUP_COMMAND`, est désormais exécuté après le script additionnel
  pré-sauvegarde même si la sauvegarde a planté. 
  La variable `PITRERY_EXIT_CODE` est définie avec le code retour de la 
  sauvegarde.
  
Configuration
-------------

Les nouveaux paramètres de configuration sont définis avec les valeurs 
par défaut suivantes :

* `BACKUP_COMPRESS_BIN` (gzip -4). `BACKUP_UNCOMPRESS_BIN`
  (gunzip). Commande à utiliser pour compresser et décompresser les 
  sauvegardes faites avec tar.
  
* `BACKUP_COMPRESS_SUFFIX` (gz). Extension apposées aux fichiers produit 
   par la commande précédente.


Mise à jour 1.6
==============

Paquet RPM
----------

* Les fichiers de configuration ont été déplacés de `/etc/sysconfig/pgsql`
  vers `/etc/pitrery` 
  

Mise à jour 1.5
==============

Configuration
-------------

Les nouveaux paramètres de configuration sont définis avec les valeurs 
par défaut suivantes :

* `PGXLOG` (vide). Chemin vers le répertoire pg_xlog s'ils sont restaurés
   ailleurs que dans PGDATA.
* `PRE_BACKUP_COMMAND` (vide) et `POST_BACKUP_COMMAND`. Commande à lancer
   avant et après la sauvegarde de base.
* `STORAGE` (tar). Méthode de sauvegarde utilisée, "tar" ou "rsync".
* `COMPRESS_BIN`, `COMPRESS_SUFFIX` et `UNCOMPRESS_BIN`. Commandes et 
   Contrôle utilisés pour compresser les fichiers WAL archivés.


Archivage
---------

Les options pour la compression sont disponibles uniquement à travers le 
fichier de configuration.
L'utilisation de l'option `-C` sur `archive_xlog` est obligatoire pour 
personnaliser ces paramètres.


Mise à jour 1.4
===============

Archivage
---------

Depuis la version 1.4, le fichier de configuration archive_xlog.conf 
n'est plus utilisé.
Tous les paramètres ont été centralisés dans `pitr.conf`
Pour la mise à jour vous devez fusionner vos fichiers dans un seul fichier
`pitr.conf`.
Vous pourrez en trouver un exemple dans DOCDIR 
(/usr/local/share/doc/pitrery par défaut) et les commentaires devraient 
être suffisants pour vous aider à reconfigurer archive_xlog.
La commande `archive_command` devrait être modifiée pour que `archive_xlog`
récupère le fichier de config.
L'option -C reconnait le "basename" du fichier de configuration et le 
cherche dans le répertoire de configuration. Le chemin complet peut aussi 
être utilisé.
	
	Exemple :

    archive_command = 'archive_xlog -C mypitr %p'

Mise à jour 1.3
================

Archivage
---------

Depuis la version 1.3, Pitrery n'essaie plus d'archiver plusieurs fichiers.
Les fichiers archive_nodes.conf ont été supprimés. Désormais, le script 
`archive_xlog` n'archive plus qu'un seul fichier.

Si vous archivez plus d'une fois, dans postgresql.conf, pour le paramètre
archive_command, vous devez enchainer votre archivage : 

    archive_command = 'archive_xlog -C archive_xlog %p && rsync -az %p standby:/path/to/archives/%f'

Bien évidement cette opération est répétable autant de fois que nécessaire.


Sauvegarde et restauration 
---------------------------

Depuis la version 1.3, La "meilleure" sauvegarde est trouvée
en enregistrant la date de fin de sauvegarde en Timestamp Unix
dans le fichier backup_timestamp qui se trouve dans chaque répertoire de 
sauvegarde.
Ce fichier peut être créé depuis le fichier backup_label grâce à ce script :

    BACKUP_DIR=/chemin/vers/répertoire/sauvegarde
    LABEL=pitr
    
    for x in ${BACKUP_DIR}/${LABEL}/[0-9]*/backup_label; do
        psql -At -c "select extract(epoch from timestamp with time zone '`awk '/^STOP TIME:/ { print $3" "$4" "$5 }' $x`');" > `dirname $x`/backup_timestamp
    done


