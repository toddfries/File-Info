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

package File::Info;

use strict;
use warnings;

use Cwd qw(abs_path);
use DBD::Pg qw(:pg_types);
use DBI qw(:sql_types);
use FDC::db;
use ReadConf;

use Fcntl ':mode';
use POSIX qw(getpid getcwd);

our @stnames = ('dev', 'ino', 'mode', 'nlink', 'uid', 'gid', 'rdev',
		'size', 'atime', 'mtime', 'ctime', 'blksize', 'blocks');
our @hnames = ('SHA384', 'SHA1', 'RIPEMD160', 'MD5');
# add SHA256 when all paths using this can be ok with doing so

sub new {
	my ($class, $dsn, $user, $pass) = @_;

	my $me = { };
	$me->{usedb} = 0;
	$me->{dsn} = $dsn;

	my $bret = bless $me, $class;
	if (defined($dsn)) {
		$me->{usedb} = 1;
		if ($dsn =~ /dbname=([^;]+)/) {
			$me->{dbname} = $1;
		}
	}
	if (!defined($me->{dbname})) {
		$me->{dbname} = "?";
	}
	if (!defined($user)) {
		$user = "";
	}
	if (!defined($pass)) {
		$pass = "";
	}
	$me->{user} = $user;
	$me->{pass} = $pass;
	if ($me->{usedb} > 0) {
		$me->init_db();
	}
	$me->{hlist} = init_hashes();
	$me->{vars}->{verbose} = 0;
	return $bret;
}

sub verbose {
	my ($me, $vset) = @_;

	if (defined($vset)) {
		print "File::Info::vars::verbose: ".$me->{vars}->{verbose};
		$me->{vars}->{verbose} = $vset;
		print " -> ".$vset."\n";
	}
	return $me->{vars}->{verbose};
}

sub dohash {
	my ($me, $file) = @_;

	if (! ($file =~ /^\//)) {
		my $abs_path = abs_path($file);
		if ($abs_path ne $file) {
			$file = $abs_path;
		}
	}

	my @statinfo = lstat($file);
	my $arg = { };
	foreach my $sn (@stnames) {
		$arg->{st}->{$sn} = shift @statinfo;
	}
	my $mode = $arg->{st}->{mode};
	if (!defined($mode)) {
		printf STDERR "File::Info:dohash(): Error stating '%s'\n",
		    $file;
		return;
	}
	$arg->{file} = $file;
	if ($file =~ /^\//) {
		$arg->{dbfn} = $file;
	} else {
		$arg->{dbfn} = getcwd()."/".$file;
	}
	$arg->{dbfn} =~ s/\/\//\//g;
	$arg->{dbfn} =~ s/\/\.\//\//g;

	my @hashes;
	if (S_ISREG($mode)) {
		@hashes = $me->gethash($arg);
	}

	return ($arg,@hashes);
}

sub init_db {
	my ($me) = @_;
	#printf "dsn='%s', user='%s', pass='%s'\n", $me->{dsn}, $me->{user}, $me->{pass};

	my $db = FDC::db->new($me->{dsn}, $me->{user}, $me->{pass});
	my $dbr = FDC::db->new($me->{dsn}, $me->{user}, $me->{pass});

	$me->{db} = $db;
	$me->{dbr} = $dbr;

	if (!defined($db)) {
		if ($me->{vars}->{verbose} > 0) {
			print "db connection error...not using!\n";
		}
		$me->{usedb} = 0;
		return;
	}
	if (!defined($dbr)) {
		if ($me->{vars}->{verbose} > 0) {
			print "dbr connection error...not using!\n";
		}
		$me->{usedb} = 0;
		return;
	}

	my @tables;

	my $dbmsname = $db->getdbh()->get_info( 17 );
	my $dbmsver  = $db->getdbh()->get_info( 18 );
	#printf "dbms name %s version %s\n", $dbmsname, $dbmsver;

	my ($serialtype,$blobtype,$tablere,$index_create_re);
	if ($dbmsname eq "PostgreSQL") {
                $serialtype = "serial";
                $blobtype = "bytea";
                $tablere = '\\.%name%$';
                #$get_pgsz = "show block_size";
                $me->{stats}->{pgsz} = 1;
                $me->{get}->{dbsz} = "SELECT  pg_database_size(datname) db_size FROM pg_database where datname = '";
                $me->{get}->{dbsz} .= $me->{dbname};
                $me->{get}->{dbsz} .= "' ORDER BY db_size";
		$me->{stats}->{pgct} = $db->do_oneret_query($me->{get}->{dbsz});
                $me->{bbt} = { pg_type => PG_BYTEA };
                $index_create_re = "CREATE %TYPE% INDEX %NAME% ON %TABLE% using btree ( %PARAMS% )";
                $db->do("SET application_name = '?/".getpid()."'");
	} else {
		$me->{usedb} = 0;
		if ($me->{vars}->{verbose} > 0) {
			printf "Unhandled dbmsname and version: %s %s",
			    $dbmsname, $dbmsver;
		}
		return;
	}

	@tables = $db->tables();

	my %tablefound;
	foreach my $tname (@tables) {
		if ($tname =~ /^(information_schema|pg_catalog)\./) {
			next;
		}
		#printf "Checking dbms table '%s'", $tname;
		foreach my $tn (('fileinfo')) {
			my $tre = $tablere;
			$tre =~ s/%name%/$tn/g;
			if ($tname =~ m/$tre/) {
				$tablefound{$tn} = 1;
			}
		}
		#print "\n";
	}

	if (!defined($tablefound{'fileinfo'})) {
		my $q = "CREATE TABLE fileinfo (";
		$q .=   "id ${serialtype}, ";
		$q .=   "name TEXT unique, ";
		$q .=   "last_validated TIMESTAMP, ";
		foreach my $HT (@hnames) {
			my $ht = lc($HT);
			$q .= "${ht} TEXT, ";
		}
		foreach my $sn (@stnames) {
			my $type = "INT";
			if ($sn eq "size") {
				$type = "BIGINT";
			}
			$q .= "${sn} ${type}, ";
		}
		$q =~ s/, $//;
		$q .=   ")";
		my $sth = $db->doquery($q);
		$sth = $me->init_db_hash($index_create_re, 'file_name_idx',
		    'fileinfo', 'name', 'UNIQUE');
		$sth = $me->init_db_hash($index_create_re, 'file_id_idx',
		    'fileinfo', 'id');
		$sth = $me->init_db_hash($index_create_re, 'file_sha1_idx',
		    'fileinfo', 'sha1');
		$sth = $me->init_db_hash($index_create_re, 'file_md5_idx',
		    'fileinfo', 'md5');
		$sth = $me->init_db_hash($index_create_re, 'file_valid_idx',
		    'fileinfo', 'last_validated');
	}
}

sub init_db_hash {
	my ($me, $re, $name, $table, $param, $type) = @_;

	if (!defined($type)) {	
		$type = "";
	}
	$re =~ s/%NAME%/$name/;
	$re =~ s/%TABLE%/$table/;
	$re =~ s/%PARAMS%/$param/;
	$re =~ s/%TYPE%/$type/;

	return $me->{db}->doquery($re)
}

sub init_hashes {
	use Crypt::Digest::MD5;
	use Crypt::Digest::SHA1;
	use Crypt::Digest::RIPEMD160;
	use Crypt::Digest::SHA256;
	use Crypt::Digest::SHA384;

	my $h = { };

	foreach my $HT (@hnames) {
		my $ht = lc($HT);

		my $class = "Crypt::Digest::$HT";
		eval "require $class";

		$h->{$ht}->{driver} = ${class}->new();

		$h->{$ht}->{name} = $ht;
	}

	return $h;
}

sub gethash {
	my ($me, $a) = @_;
	my $file = $a->{file};
	my @hashes;
	# skip db call if file is less than 512B, XXX what is a good value?
	my $sweet_spot = 512;
	if ($me->{usedb} > 0 && $a->{st}->{size} > $sweet_spot) {
		@hashes = $me->dbhash($a);
		if (@hashes) {
			return @hashes;
		}
	}

	my @hlcnames;
	foreach my $HT (@hnames) {
		my $ht = lc($HT);
		$me->{hlist}->{$ht}->{driver}->reset();
		push @hlcnames, $ht;
	}
	if (!open(F,$file)) {
		# XXX more graceful...
		print STDERR "unable to open $file";
		return (undef,undef,undef,undef);
	}
	my $data;
	# SSIZE_MAX = 32767
	while(read(F, $data, 32*1024)) {
		foreach my $ht (@hlcnames) {
			$me->{hlist}->{$ht}->{driver}->add($data);
		}
	}
	close(F);

	foreach my $ht (@hlcnames) {
		push @hashes, $me->{hlist}->{$ht}->{driver}->hexdigest();
		$me->{hlist}->{$ht}->{driver}->reset();
	}
	if ($me->{usedb} > 0) {
		$me->dbsave($a, @hashes);
	}
	return @hashes;
}
sub db_prep_alloc
{
	my ($me, $hname, $prepsql) = @_;
	if ($me->verbose > 0) {
		printf "prepalloc(%s, %s)\n", $hname, $prepsql;
	}
	if (!defined($me->{preps}->{dbinsert})) {
		$me->{preps}->{dbinsert} = $me->{db}->prepare($prepsql);
		if (!defined($me->{preps}->{dbinsert})) {
			if ($me->verbose > 0) {
				printf STDERR "prepalloc: db->prepare(%s) returned <undef>\n", $prepsql;
			}
		}
	}
	return $me->{preps}->{dbinsert};
}
sub dbinsert {
	my ($me,$a) = @_;

	if (!defined($me->{preps}->{dbinsert})) {
		my $q = "INSERT INTO fileinfo (name, ";
		my $q2 = "?, ";
		foreach my $HT (@hnames) {
			my $ht = lc($HT);
			$q .= "${ht}, ";
			$q2 .= "?, ";
		}
		foreach my $sn (@stnames) {
			$q .= "${sn}, ";
			$q2 .= "?, ";
		}
		$q =~ s/, $//;
		$q2 =~ s/, $//;
		$q .= ") VALUES (";
		$q .= $q2;
		$q .= ")";

		$me->db_prep_alloc('dbinsert', $q);
	}
	return $me->{preps}->{dbinsert};
}
sub dbsave {
	my ($me, $a, @hashes) = @_;
	my $id = $a->{db_row_id};
	my $q;
	if (defined($id)) {
		$q = "UPDATE fileinfo set ";
		foreach my $HT (@hnames) {
			my $ht = lc($HT);
			$q .= sprintf "%s = '%s', ", $ht, shift @hashes;
		}
		foreach my $sn (@stnames) {
			$q .= sprintf "%s = '%s', ", $sn, $a->{st}->{$sn};
		}
		$q .= "last_validated = now(), ";
		$q =~ s/, $//;
		$q .= " WHERE id = ${id}";
		if ($me->{vars}->{verbose} > 0) {
			printf STDERR "%s\n",$q;
		}
		$me->{db}->doquery($q);
		return;
	}
	my $h = $me->dbinsert($a);
	my $i=1;
	$h->bind_param($i++, $a->{dbfn}, SQL_CHAR);
	foreach my $HT (@hnames) {
		$h->bind_param($i++, shift @hashes, SQL_CHAR);
	}
	foreach my $sn (@stnames) {
		my $type = SQL_INTEGER;
		if ($sn eq "size") {
			$type = SQL_BIGINT;
		}
		$h->bind_param($i++, $a->{st}->{$sn}, $type);
	}
	$h->execute();
}
sub dbhash {
	my ($me, $a) = @_;

	my $st = $a->{st};
	my $fn = $a->{dbfn};
	my $qf = $me->{db}->quote($fn);
	my $q = "SELECT * FROM fileinfo where name = ".$qf;

	my $sth = $me->{dbr}->doquery($q);
	if (!defined($sth) || $sth == -1) {
		if ($me->{vars}->{verbose} > 0) {
			print STDERR "query error, sth invalid (q = '${q}')\n";
		}
		return ();
	}
	my $d = $sth->fetchrow_hashref;
	if (!defined($d)) {
		if ($me->{vars}->{verbose} > 0) {
			printf STDERR "dbhash({file =>_%s_,...}: query _%s_ returned empty\n", $fn, $q;
		}
		return;
	}
	#use Data::Dumper;
	#print Dumper($d);
	#print Dumper($st);
	if ($d->{name} ne $fn) {
		if ($me->{vars}->{verbose} > 0) {
			printf STDERR "dbhash({file =>_%s_,...}: returned d->{name} = _%s_\n", $fn, $d->{name};
		}
		return;
	}
	# if the name matches, this must be set regardless, to avoid duplicate inserts
	$a->{db_row_id} = $d->{id};
	my $mismatch = 0;
	foreach my $attr (('mtime', 'ino', 'dev', 'rdev', 'size')) {
		if (!defined($d->{$attr})) {
			if ($me->{vars}->{verbose} > 0) {
				print STDERR "d->{$attr} is undef\n";
			}
			next;
		}
		if (!defined($st->{$attr})) {
			if ($me->{vars}->{verbose} > 0) {
				print STDERR "st->{$attr} is undef\n";
			}
			next;
		}
		if ($d->{$attr} != $st->{$attr}) {
			if ($me->{vars}->{verbose} > 0) {
				printf STDERR "dbhash({file=>'%s',..}): %s !match (%s vs %s)\n", $fn, $attr, $d->{$attr}, $st->{$attr};
			}
			$mismatch ++;
		}
	}
	if ($mismatch > 0) {
		return;
	}
	my @hashes;
	foreach my $HT (@hnames) {
		my $ht = lc($HT);
		push @hashes, $d->{$ht};
	}
	return @hashes;
}

sub validate {
	my ($me, $i) = @_;
	my $count = 1000;
	if (defined($i) && $i > 0) {
		$count = $i;
	}
	my $q = "SELECT * FROM fileinfo where last_validated is null";
	$q .= " limit $count";
	printf STDERR "validating entries never validated:\n";
	my $vcount = $me->_validation($q);
	if ($vcount <= $count) {
		$count = $count - $vcount;
	} else {
		return $vcount;
	}
	# validate if over a week since last check
	$q = "SELECT * FROM fileinfo WHERE ";
	$q .= " last_validated < (NOW() - ( 86400 * 7 ) * INTERVAL '1' second)";
	$q .= " order by last_validated asc limit $count";
	printf STDERR "validating entries least recently validated:\n";
	my $vcount2 = $me->_validation($q);
	my $ret = $vcount + $vcount2;
	return $ret;
}

sub _validation {
	my ($me, $q) = @_;

	my $sth = $me->{dbr}->doquery($q);

	if (!defined($sth) || $sth == -1) {
		if ($me->{vars}->{verbose} > 0) {
			print STDERR "query error, sth invalid (q = '${q}')\n";
		}
		return 0;
	}
	my $d;
	my $count = 0;
	my @eexist = ();
	my @exist = ();
	while ($d = $sth->fetchrow_hashref) {
		$count++;
		if ($me->{vars}->{verbose} > 1) {
			printf STDERR "File::Info::validate queueing '%s'\n", $d->{name};
		}
		if (-f $d->{name}) {
			push @exist, $d->{name};
			next;
		}
		push @eexist, $d->{name};
	}
	my $ecount = 0;
	# remove !exist entries
	my $where = "where";
	foreach my $name (@eexist) {
		$ecount++;
		$where .= " name = ".$me->{db}->quote($name)." or";
	}
	if ($me->{vars}->{verbose} > 0) {
		printf STDERR "File::Info::validate deletion of %d entries starting\n", $ecount;
	}
	$where =~ s/ or$//;
	if ($where =~ /name = /) {
		$q = "delete from fileinfo $where";
		if ($me->{vars}->{verbose} > 2) {
			print STDERR "validation: $q\n";
		}
		$sth = $me->{db}->doquery($q);
	}

	# update entries that still exist in the filesystem
	$where = "where";
	$ecount = 0;
	foreach my $name (@exist) {
		$ecount++;
		$where .= " name = ".$me->{db}->quote($name)." or";
		#$me->dohash($name);
	}
	if ($me->{vars}->{verbose} > 0) {
		printf STDERR "File::Info::validate updating of %d entries starting\n", $ecount;
	}
	$where =~ s/ or$//;
	if ($where =~ /name = /) {
		$q = "update fileinfo set last_validated = now() $where";
		if ($me->{vars}->{verbose} > 2) {
			print STDERR "validation: $q\n";
		}
		$sth = $me->{db}->doquery($q);
	}
	#$q = "vacuum";
	#$me->{db}->doquery($q);
	return $count;
}

1;
