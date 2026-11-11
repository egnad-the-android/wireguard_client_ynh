Ouvrez le panneau de configuration de WireGuard Client. Utilisez Accès public (Compy) pour relier une VPS passerelle (tunnel IPv4 complet, sous-réseaux locaux exclus), ou Interfaces avancées pour envoyer un fichier de configuration WireGuard.

Après la configuration Compy, YunoHost voit l'IP publique de la VPS. Le DynDNS nohost.me se met à jour tout seul ; pour un domaine personnalisé, pointez l'enregistrement A vers la VPS et ne publiez pas d'AAAA. Définissez le PTR/rDNS de la VPS pour le courrier sortant.

Cette variante Compy n'a pas été testée sur un vrai serveur YunoHost ni sur une vraie VPS.
