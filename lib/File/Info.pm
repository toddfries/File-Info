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

use FDC::db;
use DBD::Pg qw(:pg_types);
use ReadConf;

use Fcntl ':mode';
use POSIX qw(getpid getcwd);

our @stnames = ('dev', 'ino', 'mode', 'nlink', 'uid', 'gid', 'rdev',
		'size', 'atime', 'mtime', 'ctime', 'blksize', 'blocks');
our @hnames = ('SHA384', 'SHA1', 'RIPEMD160', 'MD5');

sub new {
	my ($class, $dsn, $user, $pass) = @_;

	my $me = { };
	$me->{$dsn} = $dsn;
	$me->{usedb} = 0;

	my $bret = bless $me, $class;
	if (defined($dsn)) {
		$me->{usedb} = 1;
		if ($dsn =~ /dbname=([^;]+)/) {
			$me->{dbname} = $1;
		}
	}
	if (!defined($user)) {
		$user = "";
	}
	if (!defined($pass)) {
		$pass = "";
	}
	$me->{$user} = $user;
	$me->{$pass} = $pass;
	if ($me->{usedb} > 0) {
		$me->{db} = $me->init_db();
	}
	$me->{hlist} = init_hashes();
	return $bret;
}

sub dohash {
	my ($me, $file) = @_;

	my @statinfo = lstat($file);
	my $arg = { };
	foreach my $sn (@stnames) {
		$arg->{st}->{$sn} = shift @statinfo;
	}
	my $mode = $arg->{st}->{mode};
	if (!defined($mode)) {
		printf STDERR "Error stating '%s'\n", $line;
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

	if (S_ISREG($mode)) {
		@hashes = gethash($arg);
	}

	return ($arg,@hashes);
}

sub init_db {
	my ($me, $dsn, $user, $pass) = @_;
	my $db = FDC::db->new($dsn, $user, $pass);

	if (!defined($db)) {
		print "db connection error...not using!\n";
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
                $stats->{pgsz} = 1;
                $get_dbsz = "SELECT  pg_database_size(datname) db_size FROM pg_database where datname = '";
                $get_dbsz .= $dbname;
                $get_dbsz .= "' ORDER BY db_size";
		$stats->{pgct} = $db->do_oneret_query($get_dbsz);
                $blob_bind_type = { pg_type => PG_BYTEA };
                $index_create_re = "CREATE INDEX %NAME% ON %TABLE% using btree ( %PARAMS% )";
                $db->do("SET application_name = '?/".getpid()."'");
	} else {
		printf "Unhandled dbmsname and version: %s %s", $dbmsname,
		    $dbmsver;
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
		$q .=   "name TEXT, ";
		foreach my $HT (@hnames) {
			my $ht = lc($HT);
			$q .= "${ht} TEXT, ";
		}
		foreach my $sn (@stnames) {
			$q .= "${sn} INT, ";
		}
		$q =~ s/, $//;
		$q .=   ")";
		my $sth = $db->doquery($q);
		$sth = $me->init_db_hash($index_create_re, 'fileidx',
		    'fileinfo', 'name');
	}
	return $db;
}
sub init_db_hash {
	my ($me, $re, $name, $table, $param) = @_;
	
	$re =~ s/%NAME%/$name/;
	$re =~ s/%TABLE%/$table/;
	$re =~ s/%PARAMS%/$param/;

	return $me->{db}->doquery($re)
}

sub init_hashes {
	use Crypt::Digest::MD5;
	use Crypt::Digest::SHA1;
	use Crypt::Digest::RIPEMD160;
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
	if ($me->{usedb} > 0) {
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
		die "unable to open $file";
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
		$q =~ s/, $//;
		$me->{db}->doquery($q);
		return;
	}
	$q = "INSERT INTO fileinfo (name, ";
	my $q2 = sprintf "'%s', ", $a->{dbfn};
	foreach my $HT (@hnames) {
		my $ht = lc($HT);
		$q .= "${ht}, ";
		$q2 .= sprintf "'%s', ", shift @hashes;
	}
	foreach my $sn (@stnames) {
		$q .= "${sn}, ";
		$q2 .= sprintf "%s, ", $a->{st}->{$sn};
	}
	$q =~ s/, $//;
	$q2 =~ s/, $//;
	$q .= ") VALUES (";
	$q .= $q2;
	$q .= ")";
	$me->{db}->doquery($q);
}
sub dbhash {
	my ($me, $a) = @_;

	my $st = $a->{st};
	my $f = $a->{dbfn};
	my $q = "SELECT * FROM fileinfo where name = '${f}'";

	my $sth = $me->{db}->doquery($q);
	if (!defined($sth) || $sth == -1) {
		print STDERR "query error, sth invalid\n";
		return ();
	}
	my $d = $sth->fetchrow_hashref;
	if (!defined($d)) {
		#printf STDERR "dbhash({file =>'%s',...}: query '%s' returned empty\n", $f, $q;
		return;
	}
	#use Data::Dumper;
	#print Dumper($d);
	#print Dumper($st);
	if ($d->{name} ne $f) {
		printf STDERR "dbhash({file =>'%s',...}: returned d->{name} = '%s'\n", $f, $d->{name};
		return ();
	}
	foreach my $attr (('mtime', 'ctime', 'ino', 'dev', 'rdev', 'size')) {
		if (!defined($d->{$attr})) {
			print STDERR "d->{$attr} is undef\n";
			next;
		}
		if (!defined($st->{$attr})) {
			print STDERR "st->{$attr} is undef\n";
			next;
		}
		if ($d->{$attr} != $st->{$attr}) {
			printf STDERR "dbhash({file=>'%s',..}): %s !match (%s vs %s)\n", $f, $attr, $d->{$attr}, $st->{$attr};
			$a->{db_row_id} = $d->{id};
			return;
		}
	}
	my @hashes;
	foreach my $HT (@hnames) {
		my $ht = lc($HT);
		push @hashes, $d->{$ht};
	}
	return @hashes;
}

1;
