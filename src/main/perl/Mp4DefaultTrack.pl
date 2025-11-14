#!/usr/bin/env perl
use strict;
use warnings;
use Fcntl qw(:seek);

# -----------------------------------------
# Low-level binary helpers
# -----------------------------------------
sub ru32 {
    my ($fh, $pos) = @_;
    sysseek($fh, $pos, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 4) == 4 or die "short read";
    return unpack("N", $buf);
}

sub ru16 {
    my ($fh, $pos) = @_;
    sysseek($fh, $pos, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 2) == 2 or die "short read";
    return unpack("n", $buf);
}

sub ru8 {
    my ($fh, $pos) = @_;
    sysseek($fh, $pos, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 1) == 1 or die "short read";
    return unpack("C", $buf);
}

sub ru64 {
    my ($fh, $pos) = @_;
    sysseek($fh, $pos, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 8) == 8 or die "short read";
    my ($hi, $lo) = unpack("NN", $buf);
    return $hi * 4294967296 + $lo;
}

sub rtype {
    my ($fh, $pos) = @_;
    sysseek($fh, $pos, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 4) == 4 or die "short read";
    return $buf;
}

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
    my ($path) = @_;
    open(my $fh, "<:raw", $path) or die $!;

    my @tracks;
    my $file_len = -s $fh;

    my $pos = 0;
    while ($pos + 8 <= $file_len) {
        my $size = ru32($fh, $pos);
        my $type = rtype($fh, $pos + 4);
        my $boxsize = $size;
        my $hdr = 8;

        if ($size == 1) {
            $boxsize = ru64($fh, $pos + 8);
            $hdr = 16;
        } elsif ($size == 0) {
            $boxsize = $file_len - $pos;
        }
        if ($type eq "moov") {
            parse_moov($fh, $pos, $boxsize, \@tracks);
        }
        last if $boxsize < 8;
        $pos += $boxsize;
    }

    close($fh);
    return @tracks;
}

sub parse_moov {
    my ($fh, $start, $size, $tracks) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    while ($p + 8 <= $end) {
        my $size32 = ru32($fh, $p);
        my $type   = rtype($fh, $p + 4);
        my $boxsize = $size32;

        if ($boxsize == 1) {
            $boxsize = ru64($fh, $p + 8);
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }

        if ($type eq "trak") {
            my $info = parse_trak($fh, $p, $boxsize);
            push @$tracks, $info if $info;
        }
        last if $boxsize < 8;
        $p += $boxsize;
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

    while ($p + 8 <= $end) {
        my $size32 = ru32($fh, $p);
        my $type   = rtype($fh, $p + 4);
        my $boxsize = $size32;

        if ($boxsize == 1) {
            $boxsize = ru64($fh, $p + 8);
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }

        if ($type eq "tkhd") {
            $t{tkhdOffset} = $p + 8;
            my $ver = ru8($fh, $t{tkhdOffset});
            my $f1  = ru8($fh, $t{tkhdOffset} + 1);
            my $f2  = ru8($fh, $t{tkhdOffset} + 2);
            my $f3  = ru8($fh, $t{tkhdOffset} + 3);
            my $flags = ($f1 << 16) | ($f2 << 8) | $f3;
            $t{defaultFlag} = ($flags & 1) ? 1 : 0;

            my $cur = $t{tkhdOffset} + 4;
            $cur += ($ver == 1) ? 16 : 8;
            $t{trackId} = ru32($fh, $cur);

        } elsif ($type eq "mdia") {
            parse_mdia($fh, $p, $boxsize, \%t);
        }

        last if $boxsize < 8;
        $p += $boxsize;
    }

    return $t{trackId} ? \%t : undef;
}

sub parse_mdia {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    while ($p + 8 <= $end) {
        my $size32 = ru32($fh, $p);
        my $type   = rtype($fh, $p + 4);
        my $boxsize = $size32;

        if ($boxsize == 1) {
            $boxsize = ru64($fh, $p + 8);
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }

        if ($type eq "mdhd") {
            my $payload = $p + 8;
            $t->{mdhdOffset} = $payload;

            my $ver = ru8($fh, $payload);
            my $cur = $payload + 4;

            $cur += ($ver == 1) ? 16 : 8; # creation/modification
            $cur += 4;                    # timescale
            $cur += ($ver == 1) ? 8 : 4;  # duration

            my $packed = ru16($fh, $cur);
            $t->{language} = decode_lang($packed);

        } elsif ($type eq "hdlr") {
            # skip version+flags+predefined (8)
            my $sub = rtype($fh, $p + 8 + 8);
            if    ($sub eq "vide") { $t->{type} = "video"; }
            elsif ($sub eq "soun") { $t->{type} = "audio"; }
            elsif ($sub eq "subt" || $sub eq "sbtl" || $sub eq "text") { $t->{type} = "subtitle"; }
            else { $t->{type} = $sub; }

        } elsif ($type eq "minf") {
            parse_minf($fh, $p, $boxsize, $t);
        }

        last if $boxsize < 8;
        $p += $boxsize;
    }
}

sub parse_minf {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    while ($p + 8 <= $end) {
        my $size32 = ru32($fh, $p);
        my $type   = rtype($fh, $p + 4);
        my $boxsize = $size32;

        if ($boxsize == 1) {
            $boxsize = ru64($fh, $p + 8);
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }

        if ($type eq "stbl") {
            parse_stbl($fh, $p, $boxsize, $t);
        }

        last if $boxsize < 8;
        $p += $boxsize;
    }
}

sub parse_stbl {
    my ($fh, $start, $size, $t) = @_;
    my $end = $start + $size;
    my $p = $start + 8;

    while ($p + 8 <= $end) {
        my $size32 = ru32($fh, $p);
        my $type   = rtype($fh, $p + 4);
        my $boxsize = $size32;

        if ($boxsize == 1) {
            $boxsize = ru64($fh, $p + 8);
        } elsif ($boxsize == 0) {
            $boxsize = $end - $p;
        }

        if ($type eq "stsd") {
            $t->{stsdOffset} = $p + 8;
            my $entry = $t->{stsdOffset} + 8;
            my $sampleType = rtype($fh, $entry + 4);
            $t->{forcedFlag} = ($sampleType =~ /fcd /i) ? 1 : 0;
        }

        last if $boxsize < 8;
        $p += $boxsize;
    }
}

# -----------------------------------------
# Patchers
# -----------------------------------------
sub patch_default {
    my ($path, $offset, $set) = @_;
    open(my $fh, "+<:raw", $path) or die $!;

    sysseek($fh, $offset+1, SEEK_SET) or die $!;
    my $buf = '';
    sysread($fh, $buf, 3) == 3 or die "short read";

    my ($b1,$b2,$b3) = unpack("C3", $buf);
    my $flags = ($b1<<16)|($b2<<8)|$b3;

    if ($set) { $flags |= 1; }
    else      { $flags &= ~1; }

    my $out = pack("C3", ($flags>>16)&255, ($flags>>8)&255, $flags&255);
    sysseek($fh, $offset+1, SEEK_SET);
    syswrite($fh, $out) == 3 or die "short write";

    close($fh);
}

sub patch_forced {
    my ($path, $stsd, $set) = @_;
    return unless $stsd;

    my $entryPos = $stsd + 8;
    open(my $fh, "+<:raw", $path) or die $!;

    if ($set) {
        sysseek($fh, $entryPos+4, SEEK_SET);
        syswrite($fh, "fcd ") == 4 or die "short write";
    }
    # unset-forced can't restore original sample type

    close($fh);
}

# -----------------------------------------
# JSON printing
# -----------------------------------------
sub print_json_list {
    my (@tracks) = @_;
    print "[\n";
    my $first = 1;
    for my $t (@tracks) {
        print ",\n" unless $first;
        $first = 0;
        my $lang = defined($t->{language}) ? "\"$t->{language}\"" : "null";
        print "  {\"id\": $t->{trackId}, \"type\": \"$t->{type}\", \"lang\": $lang, \"default\": ".
              ($t->{defaultFlag}?"true":"false").", \"forced\": ".($t->{forcedFlag}?"true":"false")."}";
    }
    print "\n]\n";
}

# -----------------------------------------
# CLI
# -----------------------------------------
sub main {
    my ($cmd, $file, $id, $flag) = @ARGV;
    if (!$cmd || !$file) {
        die "Usage:\n".
            "  perl mp4track.pl list <file>\n".
            "  perl mp4track.pl set <file> <id> <default|forced>\n".
            "  perl mp4track.pl unset <file> <id> <default|forced>\n";
    }

    if ($cmd eq "list") {
        my @tracks = parse_mp4($file);
        print_json_list(@tracks);
        exit 0;
    }

    if ($cmd eq "set" || $cmd eq "unset") {
        die "need id + flag\n" unless $id && $flag;

        my @tracks = parse_mp4($file);
        my $tid = int($id);
        my $found;

        for my $t (@tracks) {
            next unless $t->{trackId} == $tid;
            $found = 1;

            if ($flag eq "default") {
                patch_default($file, $t->{tkhdOffset}, $cmd eq "set");
            } elsif ($flag eq "forced") {
                patch_forced($file, $t->{stsdOffset}, $cmd eq "set");
            } else {
                die "Unknown flag: $flag\n";
            }
            last;
        }
        die "Track not found\n" unless $found;
        exit 0;
    }

    die "Unknown command $cmd\n";
}

main();

