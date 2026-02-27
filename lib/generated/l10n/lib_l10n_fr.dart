// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'lib_l10n.dart';

// ignore_for_file: type=lint

/// The translations for French (`fr`).
class LibLocalizationsFr extends LibLocalizations {
  LibLocalizationsFr([String locale = 'fr']) : super(locale);

  @override
  String get about => 'À propos';

  @override
  String actionAndAction(Object action1, Object action2) {
    return '$action1, puis $action2 ?';
  }

  @override
  String get add => 'Ajouter';

  @override
  String get all => 'Tous';

  @override
  String get anonLoseDataTip =>
      'Vous êtes actuellement connecté anonymement. Continuer cette opération entraînera une perte de données.';

  @override
  String get app => 'Application';

  @override
  String askContinue(Object msg) {
    return '$msg. Voulez-vous continuer ?';
  }

  @override
  String get attention => 'Attention';

  @override
  String get authRequired => 'Authentification requise';

  @override
  String get auto => 'Auto';

  @override
  String get background => 'Arrière-plan';

  @override
  String get backup => 'Sauvegarder';

  @override
  String get bioAuth => 'Authentification biométrique';

  @override
  String get blurRadius => 'Rayon de flou';

  @override
  String get bright => 'Clair';

  @override
  String get cancel => 'Annuler';

  @override
  String get checkUpdate => 'Vérifier les mises à jour';

  @override
  String get clear => 'Effacer';

  @override
  String get click => 'Cliquer';

  @override
  String get clipboard => 'Presse-papiers';

  @override
  String get close => 'Fermer';

  @override
  String get content => 'Contenu';

  @override
  String get copy => 'Copier';

  @override
  String get custom => 'Personnalisé';

  @override
  String get cut => 'Couper';

  @override
  String get dark => 'Sombre';

  @override
  String get day => 'Jours';

  @override
  String delFmt(Object id, Object type) {
    return 'Voulez-vous supprimer $type ($id) ?';
  }

  @override
  String get delay => 'Délai';

  @override
  String get delete => 'Supprimer';

  @override
  String get device => 'Appareil';

  @override
  String get disabled => 'Désactivé';

  @override
  String get doc => 'Documentation';

  @override
  String get dontShowAgain => 'Ne plus afficher';

  @override
  String get download => 'Télécharger';

  @override
  String get duration => 'Durée';

  @override
  String get edit => 'Éditer';

  @override
  String get editor => 'Éditeur';

  @override
  String get empty => 'Vide';

  @override
  String get error => 'Erreur';

  @override
  String get example => 'Exemple';

  @override
  String get execute => 'Exécuter';

  @override
  String get exit => 'Quitter';

  @override
  String get exitConfirmTip => 'Appuyez à nouveau sur Retour pour quitter';

  @override
  String get exitDirectly => 'Quitter directement';

  @override
  String get export => 'Exporter';

  @override
  String get fail => 'Échec';

  @override
  String get feedback => 'Commentaires';

  @override
  String get file => 'Fichier';

  @override
  String get fold => 'Réduire';

  @override
  String get folder => 'Dossier';

  @override
  String get font => 'Police';

  @override
  String get found => 'Trouvé';

  @override
  String get hideTitleBar => 'Masquer la barre de titre';

  @override
  String get hour => 'Heures';

  @override
  String get image => 'Image';

  @override
  String get import => 'Importer';

  @override
  String get init => 'Initialiser';

  @override
  String get key => 'Clé';

  @override
  String get language => 'Langue';

  @override
  String get license => 'Licence';

  @override
  String get log => 'Journal';

  @override
  String get login => 'Se connecter';

  @override
  String get loginTip => 'Pas d\'inscription nécessaire, utilisation gratuite.';

  @override
  String get logout => 'Déconnexion';

  @override
  String get manual => 'Manuel';

  @override
  String get migrateCfg => 'Migration de configuration';

  @override
  String get migrateCfgTip =>
      'Pour s\'adapter à la nouvelle configuration requise';

  @override
  String get minute => 'Minutes';

  @override
  String get moveDown => 'Descendre';

  @override
  String get moveUp => 'Monter';

  @override
  String get name => 'Nom';

  @override
  String get network => 'Réseau';

  @override
  String get next => 'Suivant';

  @override
  String notExistFmt(Object file) {
    return '$file n\'existe pas';
  }

  @override
  String get note => 'Note';

  @override
  String get ok => 'D\'accord';

  @override
  String get opacity => 'Opacité';

  @override
  String get open => 'Ouvrir';

  @override
  String get paste => 'Coller';

  @override
  String get path => 'Chemin';

  @override
  String get preview => 'Aperçu';

  @override
  String get previous => 'Précédent';

  @override
  String get primaryColorSeed => 'Couleur principale de base';

  @override
  String get pwd => 'Mot de passe';

  @override
  String get pwdTip =>
      'Longueur de 6 à 32 caractères, peut contenir des lettres, des chiffres et des signes de ponctuation';

  @override
  String get redo => 'Rétablir';

  @override
  String get refresh => 'Actualiser';

  @override
  String get register => 'S\'inscrire';

  @override
  String get rename => 'Renommer';

  @override
  String get replace => 'Remplacer';

  @override
  String get replaceAll => 'Tout remplacer';

  @override
  String get reset => 'Réinitialiser';

  @override
  String get restore => 'Restaurer';

  @override
  String get result => 'Résultat';

  @override
  String get retry => 'Réessayer';

  @override
  String get save => 'Enregistrer';

  @override
  String get search => 'Rechercher';

  @override
  String get second => 'Secondes';

  @override
  String get select => 'Sélectionner';

  @override
  String get setting => 'Paramètres';

  @override
  String get share => 'Partager';

  @override
  String get size => 'Taille';

  @override
  String sizeTooLargeOnlyPrefix(Object bytes) {
    return 'Contenu trop volumineux, affichage des $bytes premiers caractères uniquement';
  }

  @override
  String get start => 'Démarrer';

  @override
  String get stop => 'Arrêter';

  @override
  String get success => 'Succès';

  @override
  String get switch_ => 'Interrupteur';

  @override
  String get switcher => 'Commutateur';

  @override
  String get sync => 'Synchroniser';

  @override
  String get system => 'Système';

  @override
  String get tag => 'Étiquette';

  @override
  String get tapToAuth => 'Appuyez pour vous authentifier';

  @override
  String get themeMode => 'Mode de thème';

  @override
  String get thinking => 'En train de réfléchir';

  @override
  String get timeout => 'Délai d\'attente';

  @override
  String get undo => 'Annuler';

  @override
  String get unknown => 'Inconnu';

  @override
  String get unsupported => 'Non pris en charge';

  @override
  String get update => 'Mettre à jour';

  @override
  String get upload => 'Télécharger';

  @override
  String get user => 'Utilisateur';

  @override
  String get value => 'Valeur';

  @override
  String versionHasUpdate(Object build) {
    return 'Mise à jour trouvée : v1.0.$build, cliquez pour mettre à jour';
  }

  @override
  String versionUnknownUpdate(Object build) {
    return 'Version actuelle : v1.0.$build, cliquez pour vérifier les mises à jour';
  }

  @override
  String versionUpdated(Object build) {
    return 'Version actuelle : v1.0.$build, est à jour';
  }

  @override
  String get yesterday => 'Hier';

  @override
  String get addr => 'Adresse';

  @override
  String get available => 'Disponible';

  @override
  String get convert => 'Convertir';

  @override
  String get experimentalFeature => 'Fonctionnalité expérimentale';

  @override
  String get foregroundService => 'Service de premier plan';

  @override
  String get goto => 'Aller à';

  @override
  String get invalid => 'Invalide';

  @override
  String get valid => 'Valide';

  @override
  String get max => 'Maximum';

  @override
  String get min => 'Minimum';

  @override
  String get more => 'Plus';

  @override
  String get milliseconds => 'Millisecondes';

  @override
  String get permission => 'Permission';

  @override
  String get read => 'Lire';

  @override
  String get write => 'Écrire';

  @override
  String get done => 'Terminé';

  @override
  String get speed => 'Vitesse';

  @override
  String get stat => 'Statistiques';

  @override
  String get time => 'Temps';

  @override
  String get times => 'Fois';

  @override
  String get used => 'Utilisé';

  @override
  String get view => 'Voir';

  @override
  String get askAiModel => 'Modèle';

  @override
  String get battery => 'Batterie';

  @override
  String get cmd => 'Commande';

  @override
  String get confirm => 'Confirm';

  @override
  String get conn => 'Connexion';

  @override
  String get container => 'Conteneur';

  @override
  String get customCmdDocUrl =>
      'https://github.com/lollipopkit/flutter_server_box/wiki#custom-commands';

  @override
  String get decode => 'Décoder';

  @override
  String get decompress => 'Décompresser';

  @override
  String get disconnected => 'Déconnecté';

  @override
  String get disk => 'Disque';

  @override
  String get emulator => 'Émulateur';

  @override
  String get encode => 'Encoder';

  @override
  String get force => 'Forcer';

  @override
  String get host => 'Hôte';

  @override
  String get inner => 'Interne';

  @override
  String get install => 'Installer';

  @override
  String get location => 'Emplacement';

  @override
  String get logs => 'Journaux';

  @override
  String get loss => 'Perte';

  @override
  String get menuHelp => 'Help';

  @override
  String get menuInfo => 'Info';

  @override
  String get menuNavigate => 'Navigate';

  @override
  String get menuQuit => 'Quit';

  @override
  String get menuSettings => 'Setting';

  @override
  String get menuWiki => 'Wiki';

  @override
  String get mission => 'Mission';

  @override
  String get ms => 'ms';

  @override
  String get net => 'Réseau';

  @override
  String get node => 'Nœud';

  @override
  String get notAvailable => 'Indisponible';

  @override
  String get pingAvg => 'Moy.:';

  @override
  String get pkg => 'Pkg';

  @override
  String get port => 'Port';

  @override
  String get process => 'Processus';

  @override
  String get prune => 'Élaguer';

  @override
  String get reboot => 'Redémarrer';

  @override
  String get restart => 'Redémarrer';

  @override
  String get route => 'Routage';

  @override
  String get run => 'Exécuter';

  @override
  String get running => 'En cours d\'exécution';

  @override
  String get saved => 'Enregistré';

  @override
  String get sensors => 'Capteurs';

  @override
  String get sequence => 'Séquence';

  @override
  String get server => 'Serveur';

  @override
  String get servers => 'serveurs';

  @override
  String get shutdown => 'Éteindre';

  @override
  String get snippet => 'Extrait';

  @override
  String get stats => 'Statistiques';

  @override
  String get stopped => 'Arrêté';

  @override
  String get storage => 'Stockage';

  @override
  String get suspend => 'Suspendre';

  @override
  String get temperature => 'Température';

  @override
  String get terminal => 'Terminal';

  @override
  String get test => 'Tester';

  @override
  String get theme => 'Thème';

  @override
  String get total => 'Total';

  @override
  String get totalAttempts => 'Total';

  @override
  String get traffic => 'Trafic';

  @override
  String get ttl => 'TTL';

  @override
  String get uptime => 'Temps d\'activité';
}
