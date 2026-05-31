#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:seek);

# -----------------------------------------
# MP4 language decode (ISO-639-2/T)
# -----------------------------------------
sub decode_lang {
    my ($packed) = @_;
    return undef if !$packed || $packed == 0;
    my $a = chr((($packed >> 10) & 0x1F) + 96);
    my $b = chr((($packed >> 5)  & 0x1F) + 96);
    my $c = chr(( $packed        & 0x1F) + 96);
    return "$a$b$c";
}

# -----------------------------------------
# Parse MP4 structure
# -----------------------------------------
sub parse_mp4 {
    my ($fh) = @_;
    my $file_len = -s $fh;
    my @tracks;

    my $p = 0;
    sysseek($fh, 0, SEEK_SET);
    
    while ($p + 8 <= $file_len) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);

        if ($boxsize == 1) {
            last if sysread($fh, $hdr, 8) != 8;
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $file_len - $p;
        }
        last if $boxsize < 8;

        if ($type eq "moov") {
            parse_moov($fh, $p, $boxsize, \@tracks);
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
    return @tracks;
}

sub parse_moov {
    my ($fh, $start, $size, $tracks) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    sysseek($fh, $p, SEEK_SET);
    while ($p + 8 <= $end) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);
        
        if ($boxsize == 1) {
            sysread($fh, $hdr, 8);
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }
        last if $boxsize < 8;

        if ($type eq "trak") {
            my $t = parse_trak($fh, $p, $boxsize);
            push @$tracks, $t if $t;
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
}

sub parse_trak {
    my ($fh, $start, $size) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    my %t = (
        trackId     => 0,
        type        => "unknown",
        language    => undef,
        tkhdOffset  => undef,
        stsdOffset  => undef,
        defaultFlag => 0,
        forcedFlag  => 0,
    );

    sysseek($fh, $p, SEEK_SET);
    while ($p + 8 <= $end) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);
        
        if ($boxsize == 1) {
            sysread($fh, $hdr, 8);
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }
        last if $boxsize < 8;

        if ($type eq "tkhd") {
            $t{tkhdOffset} = $p + 8;
            my $buf;
            # Read enough to cover version, flags, and Track ID in one call
            if (sysread($fh, $buf, 24) == 24) {
                my $ver = unpack("C", substr($buf, 0, 1));
                my $flags = unpack("N", "\x00" . substr($buf, 1, 3));
                $t{defaultFlag} = ($flags & 1);
                
                my $id_offset = ($ver == 1) ? 16 : 8;
                $t{trackId} = unpack("N", substr($buf, 4 + $id_offset, 4));
            }
        } elsif ($type eq "mdia") {
            parse_mdia($fh, $p, $boxsize, \%t);
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
    return $t{trackId} ? \%t : undef;
}

sub parse_mdia {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    sysseek($fh, $p, SEEK_SET);
    while ($p + 8 <= $end) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);
        
        if ($boxsize == 1) {
            sysread($fh, $hdr, 8);
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }
        last if $boxsize < 8;

        if ($type eq "mdhd") {
            $t->{mdhdOffset} = $p + 8;
            my $buf;
            sysread($fh, $buf, 1);
            my $ver = unpack("C", $buf);
            my $skip = ($ver == 1) ? 28 : 16;
            
            sysseek($fh, $p + 8 + 4 + $skip, SEEK_SET);
            if (sysread($fh, $buf, 2) == 2) {
                $t->{language} = decode_lang(unpack("n", $buf));
            }
        } elsif ($type eq "hdlr") {
            sysseek($fh, $p + 16, SEEK_SET);
            my $sub;
            if (sysread($fh, $sub, 4) == 4) {
                if    ($sub eq "vide") { $t->{type} = "video"; }
                elsif ($sub eq "soun") { $t->{type} = "audio"; }
                elsif ($sub eq "subt" || $sub eq "sbtl" || $sub eq "text") { $t->{type} = "subtitle"; }
                else                   { $t->{type} = $sub; }
            }
        } elsif ($type eq "minf") {
            parse_minf($fh, $p, $boxsize, $t);
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
}

sub parse_minf {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    sysseek($fh, $p, SEEK_SET);
    while ($p + 8 <= $end) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);
        
        if ($boxsize == 1) {
            sysread($fh, $hdr, 8);
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }
        last if $boxsize < 8;

        if ($type eq "stbl") {
            parse_stbl($fh, $p, $boxsize, $t);
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
}

sub parse_stbl {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    sysseek($fh, $p, SEEK_SET);
    while ($p + 8 <= $end) {
        my $hdr;
        last if sysread($fh, $hdr, 8) != 8;
        my ($boxsize, $type) = unpack("Na4", $hdr);
        
        if ($boxsize == 1) {
            sysread($fh, $hdr, 8);
            my ($hi, $lo) = unpack("NN", $hdr);
            $boxsize = $hi * 4294967296 + $lo;
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }
        last if $boxsize < 8;

        if ($type eq "stsd") {
            $t->{stsdOffset} = $p + 8;
            sysseek($fh, $p + 20, SEEK_SET);
            my $sampleType;
            if (sysread($fh, $sampleType, 4) == 4) {
                $t->{forcedFlag} = ($sampleType =~ /fcd /i) ? 1 : 0;
            }
        }

        $p += $boxsize;
        sysseek($fh, $p, SEEK_SET);
    }
}

# -----------------------------------------
# Patchers (Using existing active FileHandle)
# -----------------------------------------
sub patch_default {
    my ($fh, $offset, $set) = @_;
    sysseek($fh, $offset + 1, SEEK_SET) or die $!;
    
    my $buf;
    sysread($fh, $buf, 3) == 3 or die "short read";
    my ($b1, $b2, $b3) = unpack("C3", $buf);
    my $flags = ($b1 << 16) | ($b2 << 8) | $b3;

    if ($set) { $flags |= 1; }
    else      { $flags &= ~1; }

    my $out = pack("C3", ($flags >> 16) & 255, ($flags >> 8) & 255, $flags & 255);
    sysseek($fh, $offset + 1, SEEK_SET);
    syswrite($fh, $out) == 3 or die "short write";
}

sub patch_forced {
    my ($fh, $stsd, $set) = @_;
    return unless $stsd && $set;
    
    sysseek($fh, $stsd + 12, SEEK_SET);
    syswrite($fh, "fcd ") == 4 or die "short write";
}

# -----------------------------------------
# JSON printing
# -----------------------------------------
sub print_json_list {
    my (@tracks) = @_;
    print "[\n";
    for my $i (0 .. $#tracks) {
        my $t = $tracks[$i];
        my $lang  = defined($t->{language}) ? "\"$t->{language}\"" : "null";
        my $def   = $t->{defaultFlag} ? "true" : "false";
        my $fcd   = $t->{forcedFlag} ? "true" : "false";
        my $comma = ($i < $#tracks) ? "," : "";
        print "\t{\"id\": $t->{trackId}, \"type\": \"$t->{type}\", \"lang\": $lang, \"default\": $def, \"forced\": $fcd}$comma\n";
    }
    print "]\n";
}

# -----------------------------------------
# CLI
# -----------------------------------------
sub main {
    my ($cmd, $file, $id, $flag) = @ARGV;
    if (!$cmd || !$file) {
        die "Usage:\n" .
            "  perl mp4track.pl list <file>\n" .
            "  perl mp4track.pl set <file> <id> <default|forced>\n" .
            "  perl mp4track.pl unset <file> <id> <default|forced>\n";
    }

    # Open file ONCE. Read-only for listing, read-write for patching.
    my $mode = ($cmd eq "list") ? "<:raw" : "+<:raw";
    open(my $fh, $mode, $file) or die "Cannot open $file: $!\n";

    if ($cmd eq "list") {
        my @tracks = parse_mp4($fh);
        print_json_list(@tracks);
        close($fh);
        exit 0;
    }

    if ($cmd eq "set" || $cmd eq "unset") {
        die "Missing args: need id + flag\n" unless $id && $flag;
        
        my @tracks = parse_mp4($fh);
        my $tid = int($id);
        my $found = 0;

        for my $t (@tracks) {
            next unless $t->{trackId} == $tid;
            $found = 1;

            if ($flag eq "default") {
                patch_default($fh, $t->{tkhdOffset}, $cmd eq "set");
            } elsif ($flag eq "forced") {
                patch_forced($fh, $t->{stsdOffset}, $cmd eq "set");
            } else {
                close($fh);
                die "Unknown flag: $flag\n";
            }
            last;
        }
        
        close($fh);
        die "Track not found\n" unless $found;
        exit 0;
    }

    die "Unknown command: $cmd\n";
}

main();
