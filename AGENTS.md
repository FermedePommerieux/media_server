# Instructions de contribution

Cette arborescence contient des scripts shell d'automatisation pour un serveur média domestique. Merci de respecter les consignes suivantes pour toute modification :

1. **Langue & documentation**
   - Préférez les commentaires et messages utilisateur en français, en cohérence avec l'existant.
   - Documentez toute nouvelle fonctionnalité dans `README.md` ou dans un fichier dédié.

2. **Scripts shell (`bin/` et assimilés)**
   - Utilisez `bash` et activez `set -euo pipefail` au début du script.
   - Préservez les fonctions de journalisation existantes (`log`, `err`, etc.) ou offrez des équivalents cohérents.
   - Préférez les chemins configurables via variables d'environnement avec des valeurs par défaut explicites.
   - Ajoutez des vérifications pour les dépendances externes (via `command -v`/`require_bin`).

3. **Unités systemd & règles udev (`etc/`)**
   - Gardez les fichiers commentés en tête avec leur chemin d'installation cible.
   - Vérifiez la cohérence des permissions (`User=`) avec les scripts associés.

4. **Style général**
   - Limitez-vous aux utilitaires POSIX/BSD déjà utilisés lorsque c'est possible.
   - Fournissez des journaux pertinents en cas d'erreur.

Avant de soumettre une modification, exécutez ou décrivez les tests manuels pertinents (par exemple, validation de la syntaxe `shellcheck`, simulation d'unité systemd, etc.).

