# fio x collector (Platform L)

Narrow means the host-metrics receiver with only the disk scraper, every 15 s. Wide means the same receiver with all 8 scrapers, every 1 s. Wide has one receiver, `hostmetrics`. nginx's wide cell has two, `nginx` and `hostmetrics`, so the two wide cells are not identical. The collector runs in scraper mode, so its cost does not depend on the I/O rate. Unrun on hardware.

See [fio/README.md](../../README.md) for how a fio run works, what the columns mean, the hardware steps and the known caveats.
