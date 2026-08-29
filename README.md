# smart-contract-archive

Source for all contracts i've deployed onchain

This is an archive, not a workspace. Each contract is written on its own branch and only
lands on `main` once it's actually deployed, so everything on `main` corresponds to
bytecode living at a real address.

## Deployments

| Contract | Chain | Address | Deployed | Directory |
| --- | --- | --- | --- | --- |
| _nothing merged yet_ | | | | |

## Layout

One self-contained project per top-level directory. Each brings its own `foundry.toml`,
`lib/`, tests, and deploy script, and vendors its dependencies as plain files rather
than submodules — a five-year-old `forge build` should work without a network round trip
or a version guess.

```
smart-contract-archive/
  README.md                     # this file, plus the deployment table
  jacobs-suspension-market/     # one project
    foundry.toml
    lib/                        # vendored deps, committed
    src/
    script/
    test/
    broadcast/                  # deploy receipts, committed once live
```

## Workflow

```bash
git checkout main
git checkout -b my-new-contract
mkdir my-new-contract && cd my-new-contract
forge init --no-git .
```

Build it, test it, deploy it. Then, before merging:

1. Commit `broadcast/` for the real deploy. That's the receipt: address, tx hash, block,
   constructor args. It's the difference between an archive and a scratch folder.
2. Add a row to the deployment table above.
3. Merge to `main`.

```bash
git checkout main
git merge --no-ff my-new-contract
git push
```

`--no-ff` keeps each contract as one identifiable merge commit in the history.

## Notes

Build artifacts (`out/`, `cache/`) and `.env` are ignored. `.env.example` is committed so
each project documents what it needs to deploy. Anvil-chain broadcasts and dry runs are
ignored; real-network broadcasts are not.

Nothing here is audited.
