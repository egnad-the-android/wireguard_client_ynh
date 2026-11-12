Ouvrez le panneau de configuration de l'application. Utilisez **The Gate** pour relier une VPS passerelle (tunnel IPv4 complet, sous-réseaux locaux exclus), ou Interfaces avancées pour envoyer un fichier de configuration WireGuard®.

Après la configuration de The Gate, YunoHost voit l'IP publique de la VPS. Le DynDNS nohost.me se met à jour tout seul ; pour un domaine personnalisé, pointez l'enregistrement A vers la VPS et ne publiez pas d'AAAA. Définissez le PTR/rDNS de la VPS pour le courrier sortant.

Si un bouton échoue, le panneau peut n'afficher que « Failed to run action ». Les détails sont dans Outils > Journaux.
