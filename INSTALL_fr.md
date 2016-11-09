Introduction
============

pitrery est un ensemble de scripts bash permettant de gérer les sauvegardes
PITR (Point In Time Recovery) dans PostgresSQL.
Cette documentation vous expliquera comment installer cet outil, ainsi
que les différentes subtilités de mise en oeuvre pour réaliser au mieux
vos sauvegardes.


Point In Time Recovery
======================

Ce chapitre présente les principes de la "restauration à un instant donné"
(PITR) dans PostgreSQL.

En premier lieu, il est important de comprendre que PostgreSQL réalise
toutes ses écritures en double.  Chaque transaction est écrite dans
les journaux de transaction (ou WAL pour Write Ahead Log) et ensuite
ces informations sont synchronisées avec les fichiers de données
correspondants. Ceci avant que PostgreSQL n'informe l'utilisateur que
sa transaction a été validée.

Les journaux de transactions sont divisés en segments.  Les segments
sont des fichiers de 16Mo, nommés par un nombre hexadécimal, ce qui
permet de garder ces fichiers ordonnés.  Une fois que PostgreSQL a
rempli suffisamment de fichiers WAL ou qu'un super-utilisateur le
demande ou que le time-out est atteint, le moteur va déclencher un
point de contrôle (Checkpoint).  Le checkpoint dans PostgreSQL réalise
l'écriture des transactions enregistrées dans les WAL dans les
fichiers de données de la base de données.  C'est ce mécanisme qui
implique que les données sont écrites deux fois, d'abord dans les WAL
puis dans les fichiers de données.  Une fois le checkpoint passé,
PostgreSQL peut recycler ses fichiers WAL et les réutiliser pour les
transactions suivantes.

L'objectif de ce mécanisme est de ne pas perdre de données en cas de
crash de l'instance.  Si PostgreSQL détecte que l'instance n'a pas été
arrêtée proprement, lorsqu'il redémarre, il entre dans son mode de
récupération (recovery).  En relisant les journaux de transaction, ce
mode permet d'appliquer dans les fichiers de données les modifications
manquantes.

La restauration à un instant donné fonctionne suivant ces principes :
Puisque toutes les modifications de données sont enregistrées dans les
journaux de transactions, cela signifie que PostgreSQL peut appliquer
ces changements sur les fichiers de données même si ces fichiers sont
dans un état incohérent.

Pour réaliser une sauvegarde PITR, il faut donc stocker et conserver
les segments validés des journaux de transactions dans un endroit sûr.
On appelle cette opération "l'archivage des WAL".  PostgreSQL est en
mesure d'utiliser n'importe quelle commande pour réaliser cet
archivage.

Il faut aussi une copie des fichiers de données avec l'information sur
la position d'où la restauration des archives doit commencer.  Cette
opération est appelée "sauvegarde de base" (basebackup).

Une fois ces deux pré-requis opérationnels (sauvegarde de base +
WAL archivés) l'utilisateur est en mesure d'indiquer précisément à
PostreSQL à quel moment il doit arrêter d'appliquer les modifications
enregistrées dans les journaux de transactions archivés.

Cette fonctionnalité de PostgreSQL est également à la base de la
réplication. Lorsque les archives sont appliquées en continu sur une
sauvegarde de base, on obtient une seconde instance en réplication.
Même s'il est possible de mettre en place de la réplication avec
pitrery, cet outil n'est pas fait pour, il est donc plus approprié de
gérer ses sauvegardes avec pitrery et de gérer la réplication autrement.


Fonctionnement
==============

Le but de pitrery est donc de gérer l'archivage des segments de WAL
validés, d'automatiser les sauvegardes de base et la restauration des
fichiers et en préparant la récupération jusqu'à une date et heure
donnée.  Dans la conception de pitrery, ces deux actions sont
indépendantes.  De ce fait, pour archiver vos fichiers WAL et les
conserver vous n'êtes pas obligés d'utiliser le script d'archivage
fourni par pitrery.  Par exemple, si vous avez configuré un système de
réplication, basé sur la récupération constante des données, vous
pouvez continuer à utiliser votre propre script d'archivage.

Le script `archive_xlog` s'occupe de l'archivage des WAL, si vous avez
besoin d'archiver vos fichiers WAL à différents endroits vous pouvez
l'intégrer à un script d'archivage existant ou simplement modifier le
paramètre `archive_command` du fichier de configuration de PostgreSQL
(postgresql.conf). Ce script réalise la copie ainsi que la compression
des WAL, en local ou sur un serveur distant accessible par SSH.  Pour
réduire la longueur de la ligne de commande définie dans
postgresql.conf Un fichier de configuration peut être utilisé.

La gestion des sauvegardes de base est divisée en 4 parties, chacune
utilisant un script indépendant pour réaliser ces actions :
  * Sauvegarde : `backup`
  * Restauration : `restore`
  * Purge : `purge`
  * Liste : `list`

Ces actions sont appelées par `pitrery`, un wrapper qui permet
d'appeler chaque action en lui passant les options correctes,
centralisées dans un fichier de configuration pour simplifier
l'utilisation.

Lorsqu'il est bien configuré, il est possible de lancer sa restauration
avec une commande très simple et quelques options ce qui est particulièrement
utile au moment où il faut restaurer en urgence alors que le service est coupé.
D'un autre côté, ajouter quelques options à la ligne de commande permet
de modifier le comportement du script sans pour autant avoir à modifier
systématiquement le fichier de configuration.

Deux actions supplémentaires permettent de simplifier
l'administration. `check` permet de vérifier le fichier de
configuration et si PostgreSQL est correctement configuré pour le
PITR. `configure` permet de créer rapidement un fichier de
configuration à partir de la ligne de commande.

Le stockage des sauvegardes peut être fait sur un serveur distant ou
en local.  Dans le cas d'un serveur distant, celui ci doit être
accessible via ssh en mode batch (c'est-à-dire, sans avoir à insérer
un mot de passe, ce qui nécessite de configurer les clés SSH sans
passphrase). Lors de l'utilisation de la machine locale comme espace de
stockage, il est possible de sauvegarder sur un partage monté
localement.

Sur le serveur de sauvegarde, les fichiers sont organisés de la
manière suivante :

* Un répertoire de sauvegarde racine est utilisé pour stocker l'ensemble des fichiers

* Les sauvegardes sont rassemblées dans un répertoire nommé suivant
  une étiquette (ou label). Cela rend possible l'utilisation d'un même
  répertoire racine pour stocker les sauvegardes provenant de
  différentes instances.

* Dans le sous répertoire étiqueté, chaque sauvegarde est stockée dans
  un répertoire horodaté à la date de fin de la sauvegarde. Cette
  convention de nommage permet au script de restauration de déterminer
  la sauvegarde la plus appropriée pour réaliser sa restauration à un
  instant donné.

D'ailleurs, il est intéressant de savoir que les fichiers WAL archivés
peuvent être stockés dans le répertoire étiqueté, ceci tant que le
répertoire ne commence pas par un chiffre, afin d'éviter toute
confusion de celui-ci avec une sauvegarde de base.

Installation
============

Pré-requis
----------

pitrery est un ensemble de scripts bash, bash est donc indispensable.
Les outils tels que `grep`, `sed`, `awk`,`tar`, `gzip`, `ssh`,
`scp`...  que l'on peut trouver sur n'importe quel serveur linux sont
également nécessaires.

`rsync` est nécessaire pour archiver les fichiers WAL à travers le
réseau, et peut aussi être utilisé pour les sauvegardes.  Il doit donc
être installé sur le serveur où les sauvegardes sont réalisées ainsi
que sur le serveur de stockage.

GNU make doit aussi être installé pour réaliser l'installation depuis
les sources.


Installation depuis les sources
-------------------------------

La dernière version peut être téléchargée à l'adresse suivante :

https://dl.dalibo.com/public/pitrery/

Tout d'abord extraire l'archive tar :

    tar xzf pitrery-x.y.tar.gz

Puis, placez vous dans le répertoire `pitrery-x.y` et modifier le
fichier `config.mk` pour l'adapter à votre système.
Une fois cela réalisé, lancez `make` (ou `gmake`) pour remplacer
l'interpréteur et les chemins dans les scripts :

    make

Puis, installez le programme, en tant que root si besoin :

    make install


Par défaut les fichiers sont installés dans :  `/usr/local`:

* Les scripts sont installés dans `/usr/local/bin`

* Les `actions` utilisées par pitrery sont installés dans `/usr/local/lib/pitrery`

* Les exemples de fichiers de configuration sont installés dans `/usr/local/etc/pitrery`

* Les pages de manuel sont installées dans `/usr/local/share/man`

Archivage des WAL
=================

A chaque fois que PostgreSQL complète un segment de WAL, il peut lancer une
commande pour l'archiver.
N'importe quelle commande peut être définie au niveau de `archive_command`
dans postgresql.conf pour réaliser cet archivage.
Attention, PostgreSQL vérifiera uniquement le code retour de cette
commande pour valider qu'elle a fonctionné ou non.

pitrery fourni le script `archive_xlog` pour copier et éventuellement
compresser les segments de WAL sur le serveur local ou vers un serveur
distant si celui ci est joignable via SSH.
Il n'est pas obligatoire de l'utiliser, la seule contrainte est de
fournir un endroit où le script de restauration pourra récupérer les
fichiers archivés.

`archive_xlog` peut prendre en compte un fichier nommé `pitr.conf` qui
est d'ailleurs utilisé pour définir les valeurs par défaut.
Par défaut, ce fichier se trouve dans `/usr/local/etc/pitrery/pitr.conf`
Il peut être écrasé via la ligne de commande grâce à l'option `-C`
Les paramètres suivants peuvent être configurés :

* `ARCHIVE_DIR` est le répertoire cible où déposer les fichiers.

* `ARCHIVE_LOCAL` contrôle si la copie locale doit être réalisée.  Si
  ce paramètre est positionné à "yes", archive_xlog utilise cp pour
  copier les fichiers en local.

* `ARCHIVE_HOST` est le nom d'hôte cible ou l'adresse IP utilisée pour
   copier en utilisant un accès SSH.

* `ARCHIVE_USER` permet de définir un nom d'utilisateur pour l'accès
   SSH. S'il n'est pas renseigné, c'est le nom de l'utilisateur
   système qui fait tourner PostgreSQL qui est utilisé.

* `ARCHIVE_COMPRESS` active la compression du fichier WAL au moment de
   l'archivage. La compression est activée par défaut, elle peut être
   désactivée sur un serveur qui serait occupé à traiter beaucoup de
   transactions en écriture, pour éviter un problème de contention
   dans le processus d'archivage.

* `ARCHIVE_OVERWRITE` peut être configuré à "no" pour vérifier si le
   fichier à archiver n'existe pas déjà dans le répertoire de
   destination.  Cette vérification ayant un impact négatif sur les
   performances lorsque l'archivage se fait par SSH, il est positionné
   à "yes" par défaut (pas de vérification).

* `ARCHIVE_CHECK` configuré à "yes" permet de vérifier la somme md5 du
   fichier archivé. Cela permet une vérification d'intégrité dans le
   cas d'un réseau ou stockage distant peu fiable. Si le écrasement du
   fichier est autorisé en même temps que la vérification et le fichier
   de destination existe, l'archivage est réussi si la vérification md5
   fonctionne.

* `ARCHIVE_FLUSH` configuré à "yes" force la synchronisation des
   données du fichier archivé sur disque à la destination. Malgré
   l'impact négatif sur les performances, cette opération évite les
   corruptions en cas de coupure d'électricité notamment sur les
   système de stockage peu fiable.

* `SYSLOG` peut être positionné à "yes" pour envoyer les messages vers
   syslog.  Dans le cas contraire, c'est stderr qui est utilisé.
   `SYSLOG_FACILITY` et `SYSLOG_IDENT` peuvent être utilisés pour
   stocker les messages dans les fichiers de log de PostgreSQL
   lorsqu'il est configuré pour utiliser syslog. La configuration doit
   être cohérente avec celle de PostgreSQL pour que les messages du
   script `archive_xlog` soient écrit dans les journaux de PostgreSQL,
   sinon ils sont perdus.


Lorsqu'on archive sur un serveur distant, celui ci doit être accessible,
pour l'utilisateur système qui fait tourner PostgreSQL, par SSH en mode
batch, c'est-à-dire, sans avoir à saisir un mot de passe, ce qui
nécessite de configurer des clés ssh sans passphrase).

Une fois que `archive_xlog` est configuré, la configuration de PostgreSQL
doit elle aussi être modifiée pour que ce soit pris en compte.
Dans postgresql.conf, le paramètre `archive_command` doit être modifié
ainsi que les paramètres suivants :

    # PostgreSQL >= 9.0, wal_level doit être positionné à archive ou
    # hot_standby, voire logical pour PostgreSQL >= 9.4
    # Nécessite un redémarrage
    wal_level = archive

    # PostgreSQL >= 8.3, archive_mode doit être activé
    # Nécessite un redémarrage
    archive_mode = on

    # Commande d'archivage par défaut qui utilise pitr.conf
    archive_command = '/usr/local/bin/archive_xlog %p'

    # Commande d'archivage & paramètres :
    #archive_command = '/usr/local/bin/archive_xlog -C /path/to/pitr.conf %p'
    # si le fichier de configuration se trouve dans /usr/local/etc/pitrery
    #archive_command = '/usr/local/bin/archive_xlog -C pitr %p'

Il faut redémarrer le serveur PostgreSQL si les paramètres suivants `wal_level`
ou `archive_mode` ont été modifiés, sinon un simple rechargement de la
configuration suffit.


Optimiser la compression
========================

Fichiers WAL archivés
---------------------

Par défaut, `archive_xlog` utilise `gzip -4` pour compresser les
fichiers WAL, lorsque la compression est activée
(`ARCHIVE_COMPRESS="yes"`).  Il est possible d'augmenter le taux de
compression et/ou d'accélérer celle-ci en utilisant d'autres outils de
compression tel que `bzip2` ou `pigz`.  Il faut néanmoins que ces
outils supportent l'option `-c` pour envoyer les données compressées
vers la sortie standard et que les données à compresser proviennent de
l'entrée standard.  L'outil de compression peut être défini grâce au
paramètre `ARCHIVE_COMPRESS_BIN` dans le fichier de configuration.  Le
nom du fichier possédant une extension selon le type d'outil utilisé
pour la compression (par exemple "gz" or "bz2", etc), il doit être
spécifié en utilisant le paramètre `ARCHIVE_COMPRESS_SUFFIX` (sans le
".")  Cette extension est souvent obligatoire lors de l'opération
d'extraction.  L'outil d'extraction est défini avec le paramètre
`ARCHIVE_UNCOMPRESS_BIN`, la commande idoine doit prendre un fichier
compressé comme premier paramètre.

Par exemple, une compression plus rapide est faite grâce à `pigz`, une
implémentation de gzip multi-threadée.

    ARCHIVE_COMPRESS_BIN="pigz"
    ARCHIVE_UNCOMPRESS_BIN="pigz -d"

Ou une compression maximale mais lente réalisée avec `bzip2`:

    ARCHIVE_COMPRESS_BIN="bzip2 -9"
    ARCHIVE_COMPRESS_SUFFIX="bz2"
    ARCHIVE_UNCOMPRESS_BIN="bunzip"

Sauvegardes avec tar
---------------------

L'utilisation de tar pour stocker une sauvegarde induit la compression
de PGDATA ainsi que des tablespaces avec `gzip` ; cela peut être modifié
grâce aux paramètres suivants :

* `BACKUP_COMPRESS_BIN` : spécifie la commande à utiliser
  pour la compression de l'archive. La sortie de tar est "pipée" dans cette
  commande qui est alors redirigée vers le fichier cible.

* `BACKUP_COMPRESS_SUFFIX` : doit être utilisé pour indiquer à pitrery
  l'extension de l'outil de compression défini par `BACKUP_COMPRESS_BIN`.
  Obligatoire pour la restauration.

* `BACKUP_UNCOMPRESS_BIN` : spécifie la commande à utiliser pour la
  décompression de l'archive créée par la commande définie précédemment.
  Cette commande doit pouvoir utiliser des pipes (|) et que le
  paramètre `-c` renvoie la sortie de la commande sur la sortie standard
  (stdout). Les outils comme `gzip`, `bzip2`, `pigz`, `pbzip2`, `xz`
  fonctionnent de cette manière.


Utiliser pitrery pour gérer les sauvegardes
===========================================

Configuration
-------------

Une fois que l'archivage est configuré et fonctionne correctement,
pitrery peut créer, restaurer et gérer les sauvegardes de base de
l'instance PostgreSQL __locale__.

La syntaxe de la commande pitrery est la suivante :

    pitrery [options] action [options-spécifiques-à-l-action]


Chaque action est réalisée par `pitrery` en exécutant le script
correspondant se trouvant par défaut dans le répertoire
`/usr/local/lib/pitrery` Ces scripts sont indépendants, ils réalisent
l'action basée sur les options données dans la ligne de commande au
moment de l'exécution.  L'objectif de `pitrery` est d'encapsuler ces
scripts sous un seul appel en gérant les options définies dans le
fichier de configuration. Les options de chaque actions peuvent être
surchargées à l'exécution.

Avant d'utiliser `pitrery` pour sauvegarder et gérer vos sauvegardes
pour une instance PostgreSQL particulière, un fichier de configuration
devrait être créé dans le répertoire de configuration
`/usr/local/etc/pitrery` pour les informations nécessaires à la
gestion des sauvegardes pour cette instance. On recommande d'avoir un
fichier de configuration par instance.

Le fichier de configuration initial est le fichier `pitr.conf`,
contenant tous les paramètres par défaut.

Il est conseillé de copier le fichier initial sous un nom permettant de
l'associer facilement à votre instance :

    cd /usr/local/etc/pitrery
    cp pitr.conf prod.conf


Nous venons de créer un fichier de paramétrage spécifique à l'instance
de production. Il reste à modifier ce fichier pour l'adapter à la
configuration de l'instance en question.

Les premiers paramètres à définir renseignent les informations de connexion
à l'instance PostgreSQL à sauvegarder.

Il est nécessaire de pouvoir lancer les `pg_start_backup()` and
`pg_stop_backup()` pour notifier à PostgreSQL qu'une sauvegarde est en
cours. `pitrery` utilise les mêmes variables que les outils de
PostgreSQL.

* `PGDATA` chemin d'accès au répertoire des fichiers de données de l'instance.

* `PGPSQL` chemin d'accès au binaire `psql`

* Les variables habituelles pour accéder à l'instance: `PGUSER`,
  `PGPORT`, `PGHOST` and `PGDATABASE`

Si `psql` est contenu dans le PATH de l'utilisateur, la variable
associée peut être commentée, le binaire trouvé dans le $PATH sera
automatiquement utilisé.  De la même manière si d'autres variables
sont définies dans l'environnement, elles peuvent être commentées dans
le fichier de configuration.  Notez qu'il est en général plus sûr de
configurer ces variables au niveau du fichier de configuration qu'en
tant que variables d'environnement qui pourraient ne pas être
définies, par exemple, si la commande est lancée à travers par cron.

Les paramètres suivants contrôlent les différentes actions.


* `PGOWNER` est l'utilisateur système propriétaire des fichiers de l'instance.
  La définition de cet utilisateur est utile par exemple dans le cas où
  la restauration est réalisée avec l'utilisateur root et que les fichiers
  doivent être restaurés sous l'identité d'un autre utilisateur.

* `PGXLOG` spécifie le chemin ou les journaux de transactions sont stockés
   suite à la restauration, pg_xlog peut être un lien symbolique vers ce
   répertoire comme lorsque l'option -X est utilisée avec initdb.

* `BACKUP_IS_LOCAL` signifie à pitrery que les sauvegardes sont
   stockées en local. lorsque ce paramètre est défini à "yes" il n'est plus
   nécessaire d'avoir un hôte cible.

* `BACKUP_DIR` spécifie le chemin du répertoire où sont stockées les
   sauvegardes.

* `BACKUP_LABEL` défini l'étiquetage (label) utilisé pour le jeu de
   sauvegardes.  Toutes les sauvegardes vont être stockées dans un
   sous-répertoire nommé avec l'étiquette définie à cet endroit.  Cela
   permet de stocker dans BACKUP_DIR, grâce à la même installation de
   pitrery des sauvegardes d'instances différentes sans risquer de
   mélanger les fichiers.  Cette valeur est aussi utilisée lors de
   l'appel de la fonction `pg_start_backup()` concaténée avec la date
   courante.

* `BACKUP_HOST` est l'adresse IP du serveur où les sauvegardes doivent
   être stockées. `BACKUP_USER` est le nom d'utilisateur choisi pour la
   connexion SSH, si ce champ est vide l'utilisateur exécutant pitrery
   sera utilisé.


* `RESTORE_COMMAND` peut être utilisé pour définir une commande lancée
   par PostgreSQL pour restaurer un fichier WAL.  C'est utile lorsque
   l'archivage n'est pas réalisé par pitrery.  De manière générale,
   lorsqu'on utilise `archive_xlog`, ce paramètre est laissé vide, par
   défaut, l'appel de `restore_xlog` sera fait est n'a de ce fait pas
   besoin d'être défini ici.

* `PURGE_KEEP_COUNT` utilisé pour définir la rétention en terme de
  volume. Il définit le nombre de sauvegardes à conserver au moment de
  purger les anciennes sauvegardes.

* `PURGE_OLDER_THAN` utilisé pour définir la rétention en terme de
   date. Il définit combien de __jours__ les sauvegardes sont
   conservées avant d'être purgées.

   Si ces 2 paramètres sont définis, le nombre de sauvegardes
   (`PURGE_KEEP_COUNT`) sur l'âge des sauvegardes.

* `LOG_TIMESTAMP` peut être défini à "yes" pour préfixer les messages
   de log avec la date lors des opérations de sauvegarde,
   restauration ou purge.

* `USE_ISO8601_TIMESTAMPS`, configuré à "yes", permet d'utiliser le
  format ISO 8601 pour les noms de répertoire des backups. La valeur
  par défaut reste "no" pour la compatibilité ascendante, mixer les
  conventions de nommage empêche le tri des backups lors de la
  restauration.

Hooks
-----

Certaines commandes utilisateur peuvent être lancées, elles sont spécifiées
par les variables suivantes :

* `PRE_BACKUP_COMMAND` : commande lancée avant la sauvegarde.

* `POST_BACKUP_COMMAND` : commande lancée une fois la sauvegarde
   terminée.  Cette commande est lancée même si la sauvegarde se
   termine en erreur, mais pas si la sauvegarde se termine en erreur
   du fait de `PRE_BACKUP_COMMAND` ou une erreur précédente
   (e.g. l'ordre "pre -- base backup -- post" est assuré)

L'accès à PostgreSQL ou à la sauvegarde en cours est possible avec les
variables suivantes :

* `PITRERY_HOOK` nom du hook utilisé

* `PITRERY_PSQL` commande psql pour l'exécution de requêtes sur le serveur
   PostgreSQL sauvegardé.

* `PITRERY_DATABASE` Nom de la base de connexion.

* `PITRERY_BACKUP_DIR` Chemin complet du répertoire de sauvegarde.

* `PITRERY_BACKUP_LOCAL` Peut être utilisé pour tester si une connexion
   SSH est nécessaire pour atteindre le répertoire de sauvegarde.

* `PITRERY_SSH_TARGET` contient l'information utilisateur@serveur nécessaire pour
   accéder au serveur de sauvegarde.

* `PITRERY_EXIT_CODE` code retour de la sauvegarde. 0 pour réussi,
   1 pour échec.


Stockage des sauvegardes
------------------------

pitrery propose deux manières de stocker les sauvegardes de base.

La première, historique, s'appuie sur `tar` en créant une archive
compressée (avec `gzip` par défaut) pour le répertoire `PGDATA` ainsi
que pour tous les tablespaces. Cette méthode est relativement lente et
difficile à utiliser avec des instances volumineuses, même si la
compression permet de gagner beaucoup d'espace.

La seconde s'appuie sur `rsync`. Elle réalise la synchronisation de
`PGDATA` ainsi que tous les tablespaces dans un répertoire à
l'intérieur de la sauvegarde.  Elle essaie d'optimiser le transfert
des données en créant des hardlinks du précédent backup (si il a été
réalisé par la même méthode). Cette méthode permet en général de
meilleurs taux de transfert pour la sauvegarde et est fortement
recommandée pour les instances volumineuses (à partir de plusieurs
centaines de gigaoctets).

La méthode utilisée par défaut est `tar`. Cela peut être modifié par la
définition à `tar` ou `rsync` du paramètre `STORAGE` dans le fichier
de configuration.

Utilisation
-----------

Notez: toutes les commandes possèdent l'option `-?` qui affiche les
spécificités d'utilisation.

L'aide de `pitrery` est de ce fait disponible en lançant la commande
avec l'option `-?`

    $ pitrery -?
        usage: pitrery [options] action [args]
    options:
        -c file      Chemin vers le fichier de configuration
        -n           Affiche la commande sans la lancer
        -l           Liste les fichiers de configuration du répertoire par défaut
        -V           Affiche la version avant de quitter
        -?           Affiche l'aide

    actions:
        list
        backup
        restore
        purge
        check
	configure


Si l'on veut réaliser la sauvegarde de notre serveur "prod" donné en
exemple ci-dessus, le nom du fichier de configuration doit être
communiqué à pitrery via l'option `-c` Si le nom donné n'est pas un
chemin, pitrery cherchera dans son répertoire par défaut tous les
fichiers dont l'extension est `.conf`, par exemple :

    $ pitrery -c prod action

L'option `-l` affiche tous les fichiers de configuration trouvés dans le
répertoire par défaut (`/usr/local/etc/pitrery`):

    $ pitrery -l
    INFO: listing configuration files in /usr/local/etc/pitrery
    pitr
    prod

La partie `-c prod` permettra d'utiliser le fichier :
`/usr/local/etc/pitrery/prod.conf`

En ajoutant l'option `-?` après le nom de l'action, pitrery affichera les
informations d'utilisation de l'action en question.

L'option `-n` de `pitrery` peut être utilisée pour montrer la ligne de
commande de l'action, sans l'exécuter réellement.  Cela permet de
vérifier si les paramètres d'une configuration spécifique sont
corrects.  Par exemple, avec le fichier de configuration par défaut
`pitr.conf` :

    $ pitrery -n backup 192.168.0.50
    /usr/local/lib/pitrery/backup_pitr -b /var/lib/pgsql/backups \
      -l pitr -D /var/lib/pgsql/data -s tar -h /tmp -p 5432 -U postgres \
      -d postgres 192.168.0.50

Pour terminer, chaque paramètre défini dans le fichier de configuration
peut être surchargé en ajoutant le paramètre correspondant dans la ligne de
commande, par exemple, on spécifie 5433 comme port d'écoute (à la place
de 5432):

    $ pitrery -n backup -p 5433 192.168.0.50
    /usr/local/lib/pitrery/backup_pitr -b /var/lib/pgsql/backups \
      -l pitr -D /var/lib/pgsql/data -s tar -h /tmp -p 5433 -U postgres \
      -d postgres 192.168.0.50

Notez : le paramètre `BACKUP_HOST` n'est pas défini dans le fichier de
configuration utilisé pour cet exemple, c'est pour ça que l'on ajoute
l'adresse IP après l'action "backup".

Sauvegarde
----------

**Prenez garde au fait que la sauvegarde doit s'exécuter sur le
serveur PostgreSQL**, la connexion SSH est utilisée pour __pousser__
les données sur un serveur de sauvegarde, et les connexions à
PostgreSQL pour s'exécuter en __local__.

Pour réaliser une sauvegarde avec pitrery, il est nécessaire d'avoir
un fichier de configuration ou d'avoir spécifié toutes les options
dans la ligne de commande.  L'utilisation pour une sauvegarde est la
suivante :

    $ pitrery backup -?
    backup_pitr performs a PITR base backup

    Usage:
        backup_pitr [options] [hostname]

    Backup options:
        -L                   Réalise la sauvegarde en local
        -b dir               Répertoire de sauvegarde
        -l label             Étiquette liée au backup réalisé
        -u username          Nom d'utilisateur pour la connexion SSH
        -D dir               Chemin vers $PGDATA
        -s mode              Méthode de sauvegarde, tar ou rsync
        -c compress_bin      Binaire utilisé si la méthode de sauvegarde est tar
        -e compress_suffix   Extension utilisée selon le type de compression

    Connection options:
        -P PSQL              chemin vers le binaire psql
        -h HOSTNAME          Nom d'hôte du serveur de base de données
        -p PORT              Port du serveur de base de données
        -U NAME              Utilisateur utilisé pour la connexion à la base
        -d DATABASE          Base de données utilisée pour la connexion.

        -T                   Horodatage des logs
        -?                   Affiche l'aide

Par exemple, le fichier de configuration pour le serveur "prod" donné en
exemple serait le suivant :

    PGDATA="/home/pgsql/postgresql-9.4.5/data"
    PGUSER="orgrim"
    PGPORT=5945
    PGHOST="/tmp"
    PGDATABASE="postgres"
    BACKUP_IS_LOCAL="no"
    BACKUP_DIR="/backup/postgres"
    BACKUP_LABEL="prod"
    BACKUP_HOST=10.100.0.16
    BACKUP_USER=
    RESTORE_COMMAND=
    PURGE_KEEP_COUNT=2
    PURGE_OLDER_THAN=
    PRE_BACKUP_COMMAND=
    POST_BACKUP_COMMAND=
    STORAGE="tar"
    LOG_TIMESTAMP="no"
    ARCHIVE_LOCAL="no"
    ARCHIVE_HOST=10.100.0.16
    ARCHIVE_USER=
    ARCHIVE_DIR="$BACKUP_DIR/$BACKUP_LABEL/archived_xlog"
    ARCHIVE_COMPRESS="yes"
    ARCHIVE_OVERWRITE="yes"
    SYSLOG="no"
    SYSLOG_FACILITY="local0"
    SYSLOG_IDENT="postgres"

Avec ces options pitrery peut réaliser une sauvegarde :

    $ pitrery -c prod backup
    INFO: preparing directories in 10.100.0.16:/backup/postgres/prod
    INFO: listing tablespaces
    INFO: starting the backup process
    INFO: backing up PGDATA with tar
    INFO: archiving /home/pgsql/postgresql-9.4.5/data
    INFO: backing up tablespace "ts1" with tar
    INFO: archiving /home/pgsql/postgresql-9.4.5/tblspc/ts1
    INFO: stopping the backup process
    NOTICE:  pg_stop_backup complete, all required WAL segments have been archived
    INFO: copying the backup history file
    INFO: copying the tablespaces list
    INFO: backup directory is 10.100.0.16:/backup/postgres/prod/2015.12.22_17.13.54
    INFO: done



Si on examine le contenu de `/backup/postgres` sur le serveur de stockage on trouve :

    /backup/postgres
    └── prod
        ├── 2015.12.22_17.13.54
        │   ├── backup_label
        │   ├── backup_timestamp
        │   ├── pgdata.tar.gz
        │   ├── tblspc
        │   │   └── ts1.tar.gz
        │   └── tblspc_list
        └── archived_xlog
            ├── 00000001000000000000000D.gz
            ├── 00000001000000000000000E.gz
            ├── 00000001000000000000000F.gz
            ├── 000000010000000000000010.00000090.backup.gz
            └── 000000010000000000000010.gz

La sauvegarde est stockée dans le répertoire `prod/2015.12.22_17.13.54`
qui se trouve lui même dans `BACKUP_DIR`.
On a utilisé l'étiquette "prod" lorsqu'on a défini `BACKUP_LABEL`, c'est
pour cela que le premier sous-répertoire porte ce nom.
Le second sous-répertoire est horodaté à la date de fin de la
sauvegarde.
Le fichier `backup_timestamp` contient la date de fin de sauvegarde,
qui est utilisée lors des opérations de restauration
pour choisir la sauvegarde la plus appropriée pour restaurer à une
date précise.
Ce fichier est aussi utilisé aussi par l'opération de purge.
Le répertoire horodaté conserve aussi le fichier `backup_label` de
PostgreSQL, une archive du répertoire PGDATA, une archive pour chaque
tablespace ainsi que la liste des tablespaces (`tblspc_list`)
avec leur chemins.
Pour terminer, un répertoire `conf` aurait pu être créé pour conserver
les fichiers de configuration de l'instance sauvegardée (`postgresql.conf`
, `pg_hba.conf` and `pg_ident.conf`) lorsqu'ils ne se trouvent pas dans le
répertoire $PGDATA


Notes :
* Ici la configuration est laissée par défaut de telle sorte que le
  script `archive_xlog` conserve les fichiers WAL dans
  `prod/archived_xlog` de façon à les stocker à proximité des
  sauvegardes de base.
* Si la méthode `rsync` est utilisée, les archives sont remplacées par
  des répertoire avec le même "basename".


Lister les sauvegardes
----------------------

L'opération de listing permet de retrouver une sauvegarde sur le serveur
de sauvegarde ou sur le serveur local. Par défaut on affiche une liste
composée d'une sauvegarde différente pour chaque ligne.

    $ pitrery -c pitr15_local93 list
    List of local backups
    /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.05.04	19M	  2014-01-21 17:05:04 CET
    /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.20.30	365M	  2014-01-21 17:20:30 CET


L'option `-v` affiche des informations plus détaillées sur chaque sauvegarde,
comme par exemple, l'espace nécessaire à chaque tablespace :

* La valeur de "space used" concerne l'espace occupé par la sauvegarde

* Les volumes indiqués dans la partie PGDATA et Tablespaces sont calculés
  au moment de la sauvegarde et informent sur l'espace nécessaire
  à la restauration de cette sauvegarde.

Par exemple :

    $ pitrery -c pitr15_local93 list -v
    List of local backups
    ----------------------------------------------------------------------
    Directory:
      /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.05.04
      space used: 19M
      storage: tar with gz compression
    Minimum recovery target time:
      2014-01-21 17:05:04 CET
    PGDATA:
      pg_default 18 MB
      pg_global 437 kB
    Tablespaces:

    ----------------------------------------------------------------------
    Directory:
      /home/pgsql/postgresql-9.3.2/pitr/pitr15/2014.01.21_17.20.30
      space used: 365M
      storage: rsync
    Minimum recovery target time:
      2014-01-21 17:20:30 CET
    PGDATA:
      pg_default 18 MB
      pg_global 437 kB
    Tablespaces:
      "ts1" /home/pgsql/postgresql-9.3.2/ts1 (16395) 346 MB

Tout comme les autres commandes, les options d'utilisation peuvent être
affichées grâce à -?

    $ pitrery list -?
    usage: list_pitr [options] [hostname]
    options:
        -L              Listing depuis le stockage local.
        -u username     Nom de l'utilisateur utilisé pour la connexion SSH.
        -b dir          Répertoire de stockage des sauvegardes.
        -l label        Étiquette apposée lors de la réalisation de la sauvegarde.
        -v              Affiche les informations détaillées.

        -?              Affiche l'aide.

Restauration
------------

L'opération de restauration utilise une sauvegarde de base et prépare
la récupération des données nécessaires à une restauration à un instant
donné.
La date cible doit être donnée dans la ligne de commande précédé de
l'option -d.
Le format attendu est celui utilisé par PostgreSQL : `YYYY-mm-DD HH:MM:SS [+-]TZTZ`
La partie `'[+-]TZTZ'` renvoie au fuseau horaire, et doit être appliqué
sous la forme `HHMM`, tel que +2h30 vaudrait +0230 et -7h vaudrait +0700.
Cela fonctionne parfaitement avec la commande `date` disponible sur la
plupart des systèmes unix.

Selon les possibilités de la commande `date`sur votre système, il est
possible de choisir des valeurs relatives, comme par exemple, "un jour
avant" : `1 day ago`, possible avec GNU date.

L'opération de restauration se déroule de la façon suivante :

* Trouver la sauvegarde la plus récente au niveau de l'espace de stockage.

* Retrouver et extraire le contenu de PGDATA et des tablespaces.

* Créer un fichier `recovery.conf` pour PostgreSQL.

* Éventuellement, restaurer les fichiers de configurations dans un
  répertoire `PGDATA/restored_config_files`, s'ils se trouvaient
  ailleurs que dans PGDATA au moment de la sauvegarde.

* Création d'un script pouvant être utilisé optionnellement pour restaurer
  n'importe quel slot de replication qui était actif (ou inactif) au
  moment de la sauvegarde.

* Optionnellement, création d'un script de mise à jour du catalogue dans
  le cas où le chemin d'un tablespace à été modifié, pour PostgreSQL <= 9.1.

La restauration fonctionnera uniquement si le répertoire cible (PGDATA
défini dans le fichier de configuration de pitrery) ainsi que les
répertoires utilisés pour les tablespaces existent ou peuvent être
créés, modifiés et sont vides.  Il est important d'avoir préparé ces
répertoires avant de lancer la restauration.  Il est possible
d'écraser le contenu du répertoire cible grâce à l'option `-R`

En spécifiant une date cible, elle sera utilisée dans le fichier
`$PGDATA/recovery.conf` comme valeur pour le paramètre `recovery_target_time`.

A moins que `RESTORE_COMMAND` soit définie autrement, le script
`restore_xlog` va être utilisé par PostgreSQL pour récupérer les
fichiers WAL archivés.  L'utilité de ce script est de trouver, copier
vers le serveur PostgreSQL, et enfin décompresser les fichiers WAL
archivés dont PostgreSQL à besoin.  Ce comportement est défini via les
options de la ligne de commande.

Par exemple :

    restore_xlog -h HOST -d ARCHIVE_DIR %f %p

Le script de restauration utilise la configuration pour ses options,
qu'il passe à `restore_xlog` avec l'option `-C`.  Si des options
différentes de la configuration initiale doivent être communiquées à
`restore_xlog` la commande complète doit être fournie à l'opération de
restauration grace à l'option `-r`.

Imaginons que le répertoire cible soit prêt à ce qu'une restauration soit
exécutée pas l'utilisateur `postgres` , la restauration peut commencer
avec pitrery sur notre serveur "prod" :

    $ pitrery -c prod restore -d '2013-06-01 13:00:00 +0200'
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO:
    INFO: backup directory:
    INFO:   /home/pgsql/postgresql-9.1.9/pitr/prod/2013.06.01_12.15.38
    INFO:
    INFO: destinations directories:
    INFO:   PGDATA -> /home/pgsql/postgresql-9.1.9/data
    INFO:   tablespace "ts1" -> /home/pgsql/postgresql-9.1.9/ts1 (relocated: no)
    INFO:   tablespace "ts2" -> /home/pgsql/postgresql-9.1.9/ts2 (relocated: no)
    INFO:
    INFO: recovery configuration:
    INFO:   target owner of the restored files: postgres
    INFO:   restore_command = '/usr/local/bin/restore_xlog -C /usr/local/etc/pitrery/prod.conf %f %p'
    INFO:   recovery_target_time = '2013-06-01 13:00:00 +0200'
    INFO:
    INFO: checking if /home/pgsql/postgresql-9.1.9/data is empty
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts1 is empty
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts2 is empty
    INFO: extracting PGDATA to /home/pgsql/postgresql-9.1.9/data
    INFO: extracting tablespace "ts1" to /home/pgsql/postgresql-9.1.9/ts1
    INFO: extracting tablespace "ts2" to /home/pgsql/postgresql-9.1.9/ts2
    INFO: preparing pg_xlog directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO:
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO:

Le script de sauvegarde déduit que la sauvegarde à restaurer se trouve
dans `/home/pgsql/postgresql-9.1.9/pitr/prod/2013.06.01_12.15.38` sur
notre serveur de sauvegarde.
Il extrait ensuite toutes les données, y compris les tablespaces et
prépare le fichier `recovery.conf` à la racine de `$PGDATA`.
Le script demande ensuite à l'utilisateur de vérifier les informations
avant de démarrer l'instance PostgreSQL :
Ce comportement est volontaire, et permet à l'utilisateur de modifier
certains paramètres ou de modifier les spécificités de la récupération
configurées dans `recovery.conf`.

Lorsque tout est correct, l'instance PostgreSQL peut être démarrée.
Elle va appliquer toutes les modifications trouvées dans les fichiers WAL
archivés et ceci jusqu'à ce que la date cible soit atteinte. Si aucune
date cible n'a été précisée, elle consommera tous les fichiers qu'elle
trouvera dans le dossier d'archivage.

Si des questions restent en suspend au sujet des options à choisir pour
réaliser la restauration, l'option `-n` appliquée à `restore` permet
d'arrêter le traitement après avoir affiché toutes les informations.

De plus, il est possible de choisir un répertoire cible lors de la
restauration, en utilisant l'option `-D` pour définir le répertoire cible
de PGDATA, ainsi qu'en utilisant une ou plusieurs fois l'option `-t` pour
modifier le chemin du ou des tablespaces vers une autre localisation.
La syntaxe de l'option `-t` est la suivante :
 `tablespace_name_or_oid:new_directory`

Une utilisation de `-t` s'applique à un seul tablespace. Par exemple :

    $ pitrery -c prod restore -d '2013-06-01 13:00:00 +0200' \
      -D /home/pgsql/postgresql-9.1.9/data_restore \
      -t ts1:/home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: searching backup directory
    INFO: searching for tablespaces information
    INFO:
    INFO: backup directory:
    INFO:   /home/pgsql/postgresql-9.1.9/pitr/pitr13/2013.06.01_12.15.38
    INFO:
    INFO: destinations directories:
    INFO:   PGDATA -> /home/pgsql/postgresql-9.1.9/data_restore
    INFO:   tablespace "ts1" -> /home/pgsql/postgresql-9.1.9/ts1_restore (relocated: yes)
    INFO:   tablespace "ts2" -> /home/pgsql/postgresql-9.1.9/ts2 (relocated: no)
    INFO:
    INFO: recovery configuration:
    INFO:   target owner of the restored files: orgrim
    INFO:   restore_command = '/usr/local/bin/restore_xlog -C /usr/local/etc/pitrery/prod.conf %f %p'
    INFO:   recovery_target_time = '2013-06-01 13:00:00 +0200'
    INFO:
    INFO: creating /home/pgsql/postgresql-9.1.9/data_restore
    INFO: setting permissions of /home/pgsql/postgresql-9.1.9/data_restore
    INFO: creating /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: setting permissions of /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: checking if /home/pgsql/postgresql-9.1.9/ts2 is empty
    INFO: extracting PGDATA to /home/pgsql/postgresql-9.1.9/data_restore
    INFO: extracting tablespace "ts1" to /home/pgsql/postgresql-9.1.9/ts1_restore
    INFO: extracting tablespace "ts2" to /home/pgsql/postgresql-9.1.9/ts2
    INFO: preparing pg_xlog directory
    INFO: preparing recovery.conf file
    INFO: done
    INFO:
    INFO: please check directories and recovery.conf before starting the cluster
    INFO: and do not forget to update the configuration of pitrery if needed
    INFO:
    WARNING: locations of tablespaces have changed, after recovery update the catalog with:
    WARNING:   /home/pgsql/postgresql-9.1.9/data_restore/update_catalog_tablespaces.sql

Dans l'exemple ci dessus, le chemin de PGDATA a été modifié ainsi que
celui du tablespace ts1.
Jusqu'à la version 9.1 de PostgreSQL, pitrery créé un fichier SQL avec
les instructions nécessaires à la mise à jour de la colonne `spclocation`
de `pg_tablespace` (supprimée depuis la version 9.2)
Ce script doit être lancé avec des droits super-utilisateur après la
récupération sur le serveur restauré.

Encore une fois, si des doutes subsistent quant à la restauration, lancez
l'action restore avec l'option `-n` pour afficher les spécificités de la
restauration qui va être réalisée.

Les options de l'action restore sont :

    $ pitrery restore -?
    restore_pitr performs a PITR restore

    Usage:
        restore_pitr [options] [hostname]

    Restore options:
        -L                   Restauration depuis un stockage local.
        -u username          Nom d'utilisateur utilisé pour la connexion SSH.
        -b dir               Répertoire où sont stockées les sauvegardes.
        -l label             Étiquette définie lors de la sauvegarde
        -D dir               Chemin vers $PGDATA cible
        -x dir               Chemin vers le repertoire xlog (uniquement si extérieur à PGDATA.)
        -d date              Restauration jusqu'à cette date.
        -O user              Si la commande est lancée par root, propriétaire des fichiers.
        -t tblspc:dir        Modification du répertoire cible par "dir" pour le tablespace "tblspc"
                               Cette option peut être utilisée plusieurs fois
        -n                   Dry run: Affiche uniquement les informations sur la restauration
        -R                   Ecrase le répertoire cible s'il n'est pas vide.
        -c compress_bin      binaire pour décompresser les fichiers lors de l'utilisation de la méthode tar.
        -e compress_suffix   Extension utilisée par l'outil de compression

    Archived WAL files options:
        -r command           ligne de commande à utiliser la place de `restore_command`
        -C config            Fichier de configuration si `restore_xlog` est utilisé dans `restore_command`

        -T                   Horodatages des messages du log
        -?                   Affiche l'aide.



Suppression des anciennes sauvegardes
------------------------------------

L'opération de purge permet de supprimer les sauvegardes obsolètes en
s'appuyant sur les règles définies pour la rétention, soit en nombres
de sauvegardes, soit l'âge de celle ci, en nombre de jour.  Si le
nombre maximum de sauvegarde ET le nombre de jours maximum de
sauvegardes sont définis, c'est le nombre de sauvegarde qui prime.
Cela évite que toutes les sauvegardes soient supprimés s'il n'y en a
plus d'assez récente. Le script de purge essayera aussi de supprimer
les fichiers WAL archivés s'ils ne sont plus nécessaire dans la mesure
où il peut accéder à l'endroit où ces fichiers sont stockés.

L'option `-m` de la ligne de commande permet de définir le nombre
maximum de sauvegarde à conserver ( `PURGE_KEEP_COUNT` dans le fichier
de configuration) L'option `-d` de la ligne de commande permet de
définir le nombre maximum de jours où la sauvegarde sera conservée. (
`PURGE_OLDER_THAN` dans le fichier de configuration)

Par exemple, nous avons deux sauvegardes stockées,  et nous ne voulons en
conserver qu'une seule, sachant que `PURGE_KEEP_COUNT=2`:

    $ pitrery -c prod purge -m 1
    INFO: searching backups
    INFO: purging the following backups:
    INFO:  /backup/postgres/prod/2015.12.22_17.13.54
    INFO: listing WAL files older than 000000010000000000000013
    INFO: 4 old WAL file(s) to remove from 10.100.0.16
    INFO: purging old WAL files
    INFO: done

Note : si des fichiers WAL sont archivés alors qu'il n'y a pas de
sauvegarde de base, la purge ne supprimera pas ces fichiers.

Les options de purge sont :

    $ pitrery purge -?
    purge_pitr cleans old PITR backups
    usage: purge_pitr [options] [hostname]
    options:
        -L           Purge dans un stockage local
        -l label     Étiquette pour identifier les données à purger.
        -b dir       Répertoire de sauvegarde
        -u username  Nom d'utilisateur utilisé dans la connexion SSH
        -n host      Nom du serveur où se trouvent les WAL archivés.
        -U username  Nom d'utilisateur utilisé dans la connexion SSH vers le serveur où se trouvent les WAL
        -X dir       Répertoire où se trouvent les WAL

        -m count     Nombre de sauvegardes à conserver
        -d days      Nombre de jour durant lequel les sauvegardes sont conservées.
        -N 		     Dry run: Affiche uniquement les informations sur la restauration

        -T           Horodatage des messages dans les logs.
        -?           Affiche l'aide.

Comme précédemment, si des doutes subsistent quant à la purge, lancez
l'action de purge avec l'option `-N` pour afficher ce qui serait purgé.


Configuration de pitrery en ligne de commande
---------------------------------------------

L'action `configure` permet de créer rapidement un fichier de
configuration depuis la ligne de commande. Il faut lui fournir la
destination de stockage des backups, sous la forme
`[[user@]host:]/path`. Si un host n'est pas fourni, les sauvegardes se
font en local. Les options de configuration sont :

    pitrery configure -?
    configure_pitr configures pitrery

    Usage:
        configure_pitr [options] [[user@]host:]/path/to/backups

    Options:
        -o conf                Output configuration file
	-f                     Overwrite the destination file
        -C                     Do not connect to PostgreSQL

    Configuration options:
        -l label               Backup label
        -s mode                Storage method, tar or rsync
        -m count               Number of backups to keep
        -g days                Remove backup older then this number of days
        -D dir                 Path to $PGDATA
        -a [[user@]host:]/dir  Place to store WAL archives

    Connection options:
        -P psql                Path to the psql command
        -h hostname            Database server host or socket directory
        -p port                Database server port number
        -U name                Connect as specified database user
        -d database            Database to use for connection

        -?                     Print help

Seules le minimum nécessaire pour une configuration fonctionnelle est
disponible, l'objectif étant de fournir un moyen de rapidement
configurer l'outil, l'optimisation se fait par édition du fichiers de
configuration produit. Parmi les options, `-C` évite de se connecter à
PostgreSQL pour afficher les paramètres à modifier pour l'archivage
des fichiers WAL. `-o` permet d'écrire le fichier de configuration,
s'il ne s'agit pas d'un chemin, le fichier est créé dans le répertoire
de configuration par défaut.


Vérification de la configuration
--------------------------------

L'action `check` permet de vérifier un fichier de configuration. Les
tests consistent à vérifier si le répertoire de stockage des backups
est utilisable, si l'archivage est possible avec `archive_xlog`, si
PostgreSQL est accessible et correctement configuré pour le PITR et
enfin si l'utilisateur peut accéder aux fichiers à sauvegarder.

Par exemple, on peut vérifier si le fichier `local.conf` est correct:

    INFO: Configuration file is: /usr/local/etc/pitrery/local.conf
    INFO: loading configuration
    INFO: the configuration file contains:
    PGDATA="/home/pgsql/postgresql-9.5.1/data"
    PGUSER="orgrim"
    PGPORT=5951
    PGHOST="/tmp"
    PGDATABASE="postgres"
    BACKUP_IS_LOCAL="yes"
    BACKUP_DIR="/home/pgsql/pitrery"
    BACKUP_LABEL="local"
    BACKUP_HOST=
    BACKUP_USER=
    RESTORE_COMMAND=
    PURGE_KEEP_COUNT=2
    PURGE_OLDER_THAN=
    PRE_BACKUP_COMMAND=
    POST_BACKUP_COMMAND=
    STORAGE="tar"
    LOG_TIMESTAMP="no"
    ARCHIVE_LOCAL="yes"
    ARCHIVE_HOST=
    ARCHIVE_USER=
    ARCHIVE_DIR="$BACKUP_DIR/$BACKUP_LABEL/archived_xlog"
    ARCHIVE_COMPRESS="yes"
    ARCHIVE_OVERWRITE="yes"
    SYSLOG="no"
    SYSLOG_FACILITY="local0"
    SYSLOG_IDENT="postgres"

    INFO: ==> checking the configuration for inconsistencies
    INFO: configuration seems correct
    INFO: ==> checking backup configuration
    INFO: backups are local, not checking SSH
    INFO: target directory '/home/pgsql/pitrery' exists
    INFO: target directory '/home/pgsql/pitrery' is writable
    INFO: ==> checking WAL files archiving configuration
    INFO: WAL archiving is local, not checking SSH
    INFO: checking WAL archiving directory: /home/pgsql/pitrery/local/archived_xlog
    INFO: target directory '/home/pgsql/pitrery/local/archived_xlog' exists
    INFO: target directory '/home/pgsql/pitrery/local/archived_xlog' is writable
    INFO: checking rsync on the local host
    INFO: rsync found on the local host
    INFO: ==> checking access to PostgreSQL
    INFO: psql command and connection options are: psql -X -h /tmp -p 5951 -U orgrim
    INFO: connection database is: postgres
    INFO: environment variables (maybe overwritten by the configuration file):
    INFO:   PGPORT=5951
    INFO:   PGDATABASE=postgres
    INFO:   PGDATA=/home/pgsql/postgresql-9.5.1/data
    INFO: PostgreSQL version is: 9.5.1
    INFO: connection role can run backup functions
    INFO: checking the configuration:
    INFO:   wal_level = hot_standby
    INFO:   archive_mode = on
    INFO:   archive_command = 'archive_xlog -C local %p'
    INFO: ==> checking access to PGDATA
    INFO: PostgreSQL and the configuration reports the same PGDATA
    INFO: permissions of PGDATA ok
    INFO: owner of PGDATA is the current user
    INFO: access to the contents of PGDATA ok

