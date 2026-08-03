# Security

Report vulnerabilities through our [HackerOne program](https://hackerone.com/basecamp) or at
https://github.com/basecamp/once-campfire/security. Note that Campfire is in scope for our security
program, but is not bounty eligible.

## Trust model

Campfire is self-hosted and single-tenant, so the administrator is the server operator,
with shell, network, and database access already. Anything requiring the administrator
role grants nothing they do not already have, and is not a vulnerability.

We do want reports of anything a **non-administrator** can reach, and of any credential or
network path held by the Campfire process but not by the operator's own shell.

## Intentional behavior

Bot webhook URLs are administrator-configured, but Campfire still restricts them to public
HTTPS on port 443 and pins each connection to a validated DNS result. This limits the impact
of a compromised administrator session or imported configuration. Link unfurling is also
destination-restricted because any member can trigger it by pasting a URL.
