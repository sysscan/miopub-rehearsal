# miopub-rehearsal

Staging **rehearsal** artifact host for Microhub's release-safety verification (rollback artifact
preservation, activation-hash enforcement, VM5 validator coverage).

- Everything here is built from **synthetic fixture modules** (`src/games/_rehearsal_alpha`,
  `_rehearsal_beta`), never from a product game module.
- Artifacts are baked against the **staging** auth Worker and their protected containers/keys exist only
  on staging, so they cannot authenticate against production.
- Not a distribution channel. Nothing here is loadable by a customer.
