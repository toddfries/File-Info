File-Info version 0.001
========================================

This module provides a Perl api for retrieving stat and hash info from local
files.

It is a work in progress.

# INSTALLATION

To install this module type the following:

```
   perl Makefile.PL
   make
   make test
   make install
```

# DEPENDENCIES

This module requires these other modules and libraries:

```
  FDC::db
  DBD::Pg
```

The example "showinfo" additionally requires:

```
  ReadConf
```

# EXAMPLES

  To use "showinfo" a sample use case would be:

```
	$ find t lib | ./example/showinfo 
	-|-|-|-|5aa18d3f|200|t/
	c4422a446dc566db16ac9f2f6a2059e60ea66942cb71268ef0264293b9f09b07adb7feec3ebe6181bdaae7130336de5d|11fceaf2791f054f9117cda0f3fff468ecdf7d04|1a84f562a22558991940194649d0e5bc65101c11|391d5e7b41cbe1d2e35a563e0e276608|5aa18d51|1d5|t/File-Info.t
	-|-|-|-|5aa18744|200|lib/
	-|-|-|-|5aa1874c|200|lib/File/
	ef645369689194067c12259a808bb244b64eecda65bd6d449cf0c40134782eba03b222d561d711667970954c89cdd5bb|44b653b76298eef545222c0f88306d4698ae8e90|6ff4a70cc76e64c5b85c640e847c91137a7ad9b0|58a7036e539e2cdec7cb9d7160c3a5cd|5aa2d5a8|211c|lib/File/Info.pm
```

The pipe separated values above represent, in order:

```
	SHA384|SHA1|RIPEMD160|MD5|mtime|size|filename
```

# COPYRIGHT AND LICENCE

```
# Copyright (c) 2018 Todd T. Fries <todd@fries.net>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
```

# DONATIONS

If you find this useful and wish to donate, I accept donations:

- BTC: [1H3W5FxJXgLFi4rC2BbXD7L76r5BoKgyve](bitcoin:1H3W5FxJXgLFi4rC2BbXD7L76r5BoKgyve)

- DCR: [Dsn4yKM5oEWJ66idurtkboDzDt1XStpU2ej](decred:Dsn4yKM5oEWJ66idurtkboDzDt1XStpU2ej)
