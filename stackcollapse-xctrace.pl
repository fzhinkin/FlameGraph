#!/usr/bin/perl -w

use strict;
use warnings;

use Getopt::Long;
use XML::LibXML::Reader;

my $include_pname = 1;
my $include_pid = 0;
my $include_tid = 0;

sub parse_numeric_element {
    my $reader = shift;
    my $cache = shift();

    my $ref = $reader->getAttribute("ref");
    if ($ref) {
        return @$cache{$ref};
    }

    my $id = $reader->getAttribute("id");
    warn "can't read value" unless $reader->read;
    #warn "text expected"

    my $value = $reader->value + 0;
    $$cache{$id} = $value;
    return $value;
};

sub parse_thread {
    my $reader = shift;
    my $cache = shift();

    # todo: assert that $reader->name eq "thread"
    if ($reader->name ne "thread") {
        die "thread expected, but was " . $reader->name;
    }

    my $ref = $reader->getAttribute("ref");
    if ($ref) {
        return $$cache{$ref};
    }

    my $id = $reader->getAttribute("id");
    my $tid = "?";
    my $pid;
    my $comm = "";
    while ($reader->read) {
        if ($reader->nodeType == XML_READER_TYPE_END_ELEMENT && $reader->name eq "thread") {
            last;
        }
        next unless $reader->nodeType == XML_READER_TYPE_ELEMENT;
        
        if ($reader->name eq "tid") {
            $tid = parse_numeric_element($reader, $cache);
        } elsif ($reader->name eq "pid") {
            my $pid_val = parse_numeric_element($reader, $cache);
            unless($pid) {
                $pid = $pid_val;
            }
        } elsif ($include_pname && $reader->name eq "process") {
            my $ref = $reader->getAttribute("ref");
            if ($ref) {
                $comm = $$cache{$ref};
            } else {
                $comm = $reader->getAttribute("fmt");                
                $$cache{$reader->getAttribute("id")} = $comm;
            }
            $comm =~ s/ \(([0-9]*)\)$//;
            unless($pid) {
                $pid = $1;
            }
        }
    }
    unless($pid) {
        $pid = "?";
    }
    my $pname = "";
    if ($include_tid) {
		$pname = "$comm-$pid/$tid";
	} elsif ($include_pid) {
		$pname = "$comm-$pid";
	} else {
		$pname = "$comm";
	}
	$pname =~ tr/ /_/;
    $$cache{$id} = $pname;
    return $pname;
};

sub parse_frame {
    my $reader = shift;
    my $cache = shift;

    my $ref = $reader->getAttribute("ref");
    if ($ref) {
        return $$cache{$ref};
    }

    my $id = $reader->getAttribute("id");
    my $name = $reader->getAttribute("name");
    unless($name) {
        $name = "[unknown]";
    }
    $$cache{$id} = $name;
    return $name;
}

sub parse_backtrace {
    my $reader = shift;
    my $cache = shift;

    my $ref = $reader->getAttribute("ref");
    if ($ref) {
        return $$cache{$ref};
    }

    my $bt = "";
    my $id = $reader->getAttribute("id");
    while($reader->read) {
        last if $reader->nodeType == XML_READER_TYPE_END_ELEMENT && $reader->name eq "backtrace";
        next unless $reader->nodeType == XML_READER_TYPE_ELEMENT && $reader->name eq "frame";    
        my $delim = "";
        if ($bt) {
            $delim = ";";
        }
        $bt = parse_frame($reader, $cache) . $delim . $bt;
    }
    $$cache{$id} = $bt;
    return $bt;
}

GetOptions('pid' => \$include_pid,
           'tid' => \$include_tid)
or die <<USAGE_END;
USAGE: $0 [options] infile > outfile\n
	--pid		# include PID with process names
	--tid		# include TID and PID with process names

    The script process an output of the `xctrace export` command. If exported results contains multiple
    tables, all of them will be processed.
    Currently, only following table types are supported:
    - cpu-profile;
    - time-profile;
    - counters-profile.
USAGE_END

my $input = shift;
my $reader;
if ($input eq "--") {
    $reader = XML::LibXML::Reader->new(FD => fileno(STDIN));
} else {
    $reader = XML::LibXML::Reader->new(location => $input);
}

my %collapsed;
my $schema;

while(1) {
    # skip all elements until <schema name="XXX"> where "XXX" will be on of supported table types
    while($reader->read) {
        next unless $reader->nodeType == XML_READER_TYPE_ELEMENT;
        next if $reader->name ne "schema";
        $schema = $reader->getAttribute("name");
        if ($schema ne "time-profile" && $schema ne "cpu-profile" && $schema ne "counters-profile") {
            warn "Unsupported schema: $schema";
            next;
        } else {
            last;
        }
    }
    my %cache = ();
    # parse <row> elements until we find closing </node> tag.
    while($reader->read) {
        last if $reader->nodeType == XML_READER_TYPE_END_ELEMENT && $reader->name eq "node";
        next unless $reader->nodeType == XML_READER_TYPE_ELEMENT && $reader->name eq "row";

        my $weight;
        my $pname = "?";
        my $backtrace;

        while($reader->read) {
            last if $reader->nodeType == XML_READER_TYPE_END_ELEMENT && $reader->name eq "row";
            next unless $reader->nodeType == XML_READER_TYPE_ELEMENT;
            my $name = $reader->name;
        
            if ($name eq "thread") {
                $pname = parse_thread($reader, \%cache);        
            } elsif ($name eq "weight" or $name eq "cycle-weight" or $name eq "pmc-event") {
                die "Multiple sample weight values." if $weight;
                $weight = parse_numeric_element($reader, \%cache);       
            } elsif ($name eq "backtrace") {
                $backtrace = parse_backtrace($reader, \%cache);
            }
        }
        next unless($backtrace);
        unless($weight) {
            $weight = 1;
        }

        my $stack = "$pname;$backtrace";
        $collapsed{$stack} += $weight;
    }
    last unless $reader->isValid;
}

foreach my $k (sort { $a cmp $b } keys %collapsed) {
	print "$k $collapsed{$k}\n";
}