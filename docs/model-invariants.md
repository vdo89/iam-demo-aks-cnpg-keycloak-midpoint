# Network intent model invariants

Deze notitie documenteert welke harde invarianten, schema‑regels en OPA‑policies nog nodig zijn om het netwerk‑intent model "juridisch dicht" te krijgen. Ze is opgebouwd rond de zeven blokken uit de review.

## 1. Schema‑laag: strikt contract
- **Permit only what is declared:** overal `additionalProperties: false` en, waar van toepassing, `minItems`, `uniqueItems`, `format` en strikte `pattern` regels.
- **Enumeraties en ontologie:** `vrf.zone` ∈ `{PLATFORM, TENANT, STORAGE, DMZ}`; `type` ∈ `{l2vni, l3vni, rt}`.
- **VIP‑export:** alleen host‑routes `/32` en `/128`; subnet‑exports blokkeren. Zet dit dubbel vast: zowel in schema als in OPA.
- **L2VNI‑consistentie:** schema vereist `l2vniBase` (integer) + `vlan` (integer). OPA valideert `l2vni == l2vniBase + vlan` en meldt de afwijking met pad en hint.

## 2. EVPN/RT‑invariants
- Geen wees‑L2VNI zonder bijbehorende L3VNI in dezelfde VRF.
- Uniciteit: L3VNI per VRF uniek; VLAN per fabric uniek; IP‑prefixes disjunct over tenants.
- Scope‑controle: L2VNI’s alleen geactiveerd op leaf‑pairs van het mobiliteitsdomein (klein flood‑set).
- Ceph‑realiteit: alleen specifieke `/32` en `/128` Ceph‑public VIPs mogen gelekt worden; geen subnetten of willekeurige route‑sets naar andere tenants.

## 3. IPv6 afronden
- Dual‑stack tests voor v4/v6 combinaties en mixed allowlists.
- Reserve‑adressen blokkeren: link‑local, multicast en ULA tenzij expliciet toegestaan.
- VIP‑normalisatie: canonicaliseer compressie in policy zodat diff/noise verdwijnt.

## 4. OPA‑policies: boodschap en structuur
- **Stijl:** `deny[msg]` met volledig pad naar de fout en een korte fix‑hint.
- **Packages:** scheid in kleine pakketten `schema`, `naming`, `routing`, `vni`, `exposure`.
- **Strict toggle:** `data.policy.strict = true` als default; foutboodschap vermeldt of strict of lenient geldt.

## 5. Testdekking
- Negatieve bundels: duplicate VLAN, overlappende IPAM, ontbrekende RT‑match, L2VNI op te veel leafs, subnet‑export poging.
- Fuzz‑cases rond grenswaarden (bijv. VLAN 199/200/201 bij base‑offset 11000).
- Performance: `opa check`, `opa fmt`, `opa test -v` en `opa build` (Wasm artefact) in CI.

## 6. CI/CD en GitOps
- **Pre‑merge CI:** JSON Schema lint (`ajv` of `yajsv`), `opa test`, `conftest test` tegen `./examples`, `yamlfmt/prettier`, `opa fmt`, security lint (bijv. `gitleaks`).
- **Pre‑prod:** Argo sync → post‑sync hook draait `conftest` tegen de gerenderde netwerk‑config zodat beleid ook op het eindresultaat geldt.
- **DCIM‑feed:** NetBox levert authoritative facts (prefix, VLAN, device, rack); Git bevat de normen. OPA verifieert intent versus NetBox‑data.

## 7. Documentatie en UX
- Kies één naamstijl (kebab- of snake_case) en voer die consequent door in alle keys en voorbeelden.
- Maak de mappenstructuur expliciet: `/schema`, `/policy`, `/tests`, `/examples`, `/pipelines`.
- Strict mode is default; lenient is een bewuste override in `data/`.
- Error UX: elke `deny` bevat pad, regel en een hint hoe te fixen.

## 8. Golden path en mapping
- Zie [`examples/network-intent-golden-path.yaml`](../examples/network-intent-golden-path.yaml) voor een minimaal YAML‑voorbeeld met twee tenants, één platform‑ en één storage‑VRF, plus host‑route exports.
- Voeg aan README een sectie "Model invariants" met: `l2vni = base + vlan`, RT‑symmetrie en toegestane leaks (alleen firewall‑VRF), host‑route‑only VIP‑exports en mobiliteitsdomein‑scope voor L2VNI’s.
- Maak een mapping tabel intent → NX‑OS CLI (VNI, NVE, SVI, RT, route‑map, BFD, eBGP) zodat operators de koppeling zien.

Met deze lijst staat het contract dicht, zijn policies gestructureerd en weten operators én CI wat er verwacht wordt.
