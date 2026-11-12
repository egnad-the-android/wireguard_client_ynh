Utilisez la page **The Gate** du panneau de configuration pour donner une IP publique à votre Compy (ce serveur YunoHost) via une VPS Debian bon marché, ou la page Interfaces avancées pour envoyer des fichiers de configuration WireGuard® classiques.

Après la configuration de The Gate, ce serveur envoie tout le trafic Internet IPv4 via la VPS, sauf les réseaux locaux (LAN, RFC1918, CGNAT Starlink). YunoHost voit alors l'IP publique de la VPS : diagnostic, Let's Encrypt, DynDNS nohost.me (automatique, sans `dyndns update --ipv4` manuel) et le courrier sortant utilisent cette adresse. Définissez un enregistrement PTR/rDNS pour la VPS dans le panneau du fournisseur. Pour un domaine personnalisé, pointez l'enregistrement A vers la VPS et ne publiez pas d'enregistrement AAAA (IPv6 Internet est désactivé tant que le tunnel est actif ; réglez l'exposition DNS sur IPv4 uniquement).

La VPS est un point de défaillance unique et tout le débit transite par elle (l'offre OVH US standard est typiquement illimitée à 500 Mbps). Si la VPS tombe, votre Compy perd Internet jusqu'à ce que le chien de garde (environ 3 minutes) abatte le tunnel, ou que vous cliquiez sur Couper le tunnel. Le LAN et le SSH local restent joignables. La mise en service vérifie d'abord la connectivité et annule automatiquement le changement en cas d'échec.

Si un bouton échoue, le panneau peut n'afficher que « Failed to run action ». Les détails sont dans Outils > Journaux (ou `yunohost log show`). Si une entrée de journal reste ouverte, exécutez `sudo systemctl restart yunohost-api`.

Ce paquet est un fork de YunoHost-Apps/wireguard_client_ynh. Il n'est pas affilié à YunoHost ni à WireGuard, et n'est pas approuvé par eux. WireGuard est une marque déposée de Jason A. Donenfeld.
