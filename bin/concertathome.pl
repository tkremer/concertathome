#!/usr/bin/perl

# concertathome.pl - script for aligning and mixing multiple video/audio files

# Copyright (c) 2020 Thomas Kremer

# This program is free software; you can redistribute it and/or modify it
# under the terms of the GNU General Public License version 2 or 3 as
# published by the Free Software Foundation.

# external dependencies:
#   ffmpeg, ffprobe, libjson-perl

use strict;
use warnings;
use POSIX qw(floor ceil);
use Fcntl ":flock";
use File::Spec;
use File::Basename;
use File::Temp ();
use IPC::Open3;
use JSON;

my $florex = qr/[-+]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?/;
my $json = JSON->new->relaxed->utf8->pretty->canonical;
my $debug = 1;

### common functions

sub do_system {
  my @args = @_;
  for (@args) {
    die "undef in system()" unless defined;
    utf8::encode($_);
  }
  print STDERR "CMD: ",join(" ",map "<$_>", @args),"\n" if $debug;
  return system(@args);
}

sub slurp {
  my $fname = shift;
  utf8::encode($fname);
  open(my $f,"<",$fname) or die "cannot slurp \"$fname\": $!";
  local $/ = undef;
  my $content = <$f>;
  close($f);
  return $content;
}

sub load_json {
  return $json->decode(slurp(@_));
#   my ($fname) = @_;
#   open(my $f,"<",$fname) or die "cannot open \"$fname\" for reading: $!";
#   local $/ = undef;
#   my $data = <$f>;
#   close($f);
#   return $json->decode($data);
}

# TODO: do we want locks and/or atomical operation via moves?
sub store_json {
  my ($fname,$value,$overwrite_mode) = @_;
  utf8::encode($fname);
  $overwrite_mode //= "";
  if (-e $fname && $overwrite_mode ne "overwrite") {
    if ($overwrite_mode eq "merge") {
      my $oldval = load_json($fname);
      for (keys %$value) {
        $$oldval{$_} = $$value{$_};
      }
      $value = $oldval;
    } else {
      die "file already exists: \"$fname\"";
    }
  }
  my $data = $json->encode($value);
  open(my $f,">",$fname) or die "cannot open \"$fname\" for writing: $!";
  print $f $data;
  close($f);
}

# sub dirname {
#   my $file = shift;
#   $file =~ s{/[^/]*$}{} or $file = ".";
#   return $file;
# }

### create_mix

# TODO: support starttime and all the other mix features

sub create_mix {
  my @spec = @_;
  for (@spec) {
    if (/^([^=])=(.*)/) {
      $_ = [$1,0+$2];
    } else {
      $_ = [$_,1];
    }
  }
  #print JSON->new->utf8->pretty->encode({files => \@spec}),"\n";
  print $json->encode({files => \@spec}),"\n";
}

### sync_detect

# usage:
#   $0 <syncjson-file>...
#
# The syncjson file needs a "file" entry pointing to the video/audio file.
# It should have a "syncmode" entry with value "twoclap", "oneclap",
# "trackstart", "none" or "manual". If none is given, it is se to "twoclap".

sub find_claps {
  my ($infile,%args) = @_;
  #my $debug = (shift//"") eq "debug";
  $args{start} //= 0.5;
  $args{end} //= 10;
  $args{minlen} //= 0.002;
  $args{maxlen} //= 0.5;

  # we cannot significantly reduce -loglevel here, because the silencedetect
  # filter works by writing log output.
  my @cmd = (qw(ffmpeg -hide_banner -nostats -nostdin -i),$infile,
             qw(-af silencedetect=noise=-25dB:duration=0.1 -f null -));
             #qw(-af silencedetect=noise=-10dB:duration=0.1 -f null -));

  my ($c_in,$c_out);
  my $pid = open3($c_in, $c_out, 0,@cmd);

  my @claps;
  local $_;

  while (<$c_out>) {
    if (/^\[silencedetect [^]]*\] silence_(?|(start): *+($florex)$|(end): *+($florex) )/) {
      my ($type,$pos) = ($1,$2);
      if ($type eq "end") {
        push @claps,[$pos,undef];
      } elsif (@claps) {
        my $start = $claps[-1][0];
        my $end = $pos;
        my $len = $end-$start;
        my $mid = ($end+$start*4)/5;
        #my $mid = ($pos+$claps[-1][0]*4)/5;
        #if ($len > 0.002 && $len < 0.5 && $start > 0.5) {
        if ($len > $args{minlen} && $len < $args{maxlen}
            && $start > $args{start}) {
          $claps[-1] = [$mid,$len];
        } else {
          pop @claps;
        }
        #$claps[-1][1] = $pos;
        #$claps[-1][2] = ($pos+$claps[-1][0]*4)/5;
        #$claps[-1][3] = $pos-$claps[-1][0];
      }
      #last if $pos > 10;
      last if $pos > $args{end};
    }
    #print $_;
  }
  close($c_in);
  close($c_out);
  kill $pid;

  pop @claps if @claps && !defined $claps[-1][1];
  return \@claps if $args{with_length};
  $_=$$_[0] for @claps;
  return \@claps;
}

sub find_sync {
  my ($file,$syncmode) = @_;
  if ($syncmode eq "trackstart" || $syncmode eq "none") {
    return { sync => 0 };
  }
  my $claps = find_claps($file);
  my $res = { all_claps => $claps };
  my $n = $syncmode eq "twoclap" ? 2 : $syncmode eq "oneclap" ? 1 : undef;
  
  die "invalid syncmode" if !defined $n;
  if (@$claps < $n) {
    die "not enough claps in \"$file\"";
  }
  $$res{sync} = $$claps[$n-1];
  return $res;
}

sub sync_detect {
  die "need one syncjson file" unless @_;
  my ($json_file,$update) = @_;
  $update = ($update//"") eq "update";

  my $dir = dirname($json_file);
  #my $dir = $json_file =~ s/^.*\///rs;
  my $data = load_json($json_file);
  die "syncjson needs a filename" unless defined $$data{file};
  return if $update && defined $$data{sync};
  my $filename = $dir."/".$$data{file};
  $$data{syncmode} //= "twoclap";
  my $syncmode = $$data{syncmode};
  if ($syncmode eq "manual") {
    die "manual syncmode without sync" if !defined $$data{sync};
    return;
  }
  my $syncdata = find_sync($filename,$syncmode);
  for (keys %$syncdata) {
    $$data{$_} = $$syncdata{$_};
  }
  store_json($json_file,$data,"overwrite");
}

### make_mix

sub get_avfile_info {
  my $fname = shift;
  utf8::encode($fname);
  my @cmd = (qw(ffprobe -hide_banner -loglevel error -show_streams),$fname);
  open(my $f,"-|",@cmd) or die "cannot exec ffprobe: $!";
  local $_;
  my @streams;
  my $current = undef;
  while (<$f>) {
    chomp;
    if (/^(?:\[(\/?)STREAM\]|([^=]+)=(.*))$/) {
      if (!defined $1) {
        die "parse error" if !defined $current;
        $current->{$2} = $3;
      } elsif ($1 eq "") {
        die "parse error" if defined $current;
        $current = {};
      } else {
        die "parse error" if !defined $current;
        push @streams, $current;
        $current = undef;
      }
    } else {
      die "parse error: unrecognized line \"$_\"";
    }
#     if (/^\[STREAM\]$/) {
#       die "parse error" if defined $current;
#       $current = {};
#     } elsif (/^\[\/STREAM\]$/) {
#       die "parse error" if !defined $current;
#       push @streams, $current;
#       $current = undef;
#     } elsif (/^([^=]+)=(.*)$/) {
#       die "parse error" if !defined $current;
#       $current->{$1} = $2;
#     } else {
#       die "parse error: unrecognized line \"$_\"";
#     }
  }
  close($f);
  my ($v,$a);
  for (@streams) {
    if ($_->{codec_type} eq "video" && !defined $v) {
      $v = $_;
    }
    if ($_->{codec_type} eq "audio" && !defined $a) {
      $a = $_;
    }
  }
  return { video => $v, audio => $a, streams => \@streams };
}

sub get_mix_files {
  my ($mixinfo,$basedir) = @_;
  my $spec = $mixinfo->{files};
  my @files;
  my $filelist;
  my $proplist;
  if (ref $spec eq "ARRAY") {
    for my $s (@$spec) {
      if (ref $s eq "ARRAY") {
        push @files,
          {file => $$s[0], weight => $$s[1]//1, stereo => $$s[2]//[1,1]};
      } elsif (ref $s eq "HASH") {
        if (defined $$s{file}) {
          push @files, $s;
        } elsif (defined $$s{files}) {
          if (!defined $filelist) {
            $filelist = [ sort grep /\.syncjson$/, do_ls($basedir)];
            #print STDERR "filelist=[",join(" ", @$filelist),"]\n";
          }
          # TODO: if we can't trust the file, we may need to use a linear-time regex matcher instead of perl's. There is no arbitrary code execution here, but an algorithmic denial of service.
          my $rex = $$s{files};
          die "bad rex" if ref $rex ne "";
          $rex = qr/^$rex\.syncjson$/s;
          #$rex = NFA->new(rex => $rex."\\.syncjson");
          my @candidates = grep /$rex/, @$filelist;
          #print STDERR "$rex matches [".join(" ",@candidates)."]\n";
          if (defined $$s{match}) {
            my @k = keys %{$$s{match}};
            my @rexes = values %{$$s{match}};
            for (@rexes) {
              die "bad rex" if ref $_ ne "";
              $_ = qr/^$_$/s;
              #$_ = NFA->new(rex => $_);
            }
            for my $cand (@candidates) {
              my $props = $$proplist{$cand};
              if (!defined $props) {
                my $fname = $basedir."/".$cand;
                eval {
                  $props = load_json($fname);
                  my $d = dirname($fname);
                  $props->{file} =~ s/^/$d\//;
                  $$proplist{$cand} = $props;
                };
                if ($@) {
                  undef $cand;
                  last;
                }
              }
              for my $i (0..$#k) {
                undef $cand,last unless ($$props{$k[$i]}//"") =~ $rexes[$i];
              }
            }
          }
          @candidates = grep defined, @candidates;
          next unless @candidates;
          for (@candidates) {
            push @files, {file => $_, weight => $$s{weight}//1,
                      stereo => $$s{stereo}//[1,1], props => $$proplist{$_},
                      only => $$s{only}//""};
          }
        } else {
          die "need \"file\" or \"files\".";
        }
      } elsif (defined $s && ref $s eq "") {
        push @files, {file => $s, weight => 1, stereo => [1,1]};
      } else {
        die "invalid type";
      }
    }
  } else {
    die "expected an array of files";
  }
  for (@files) {
    if (!defined $$_{props}) {
      my $file = $$_{file};
      my $props = $$proplist{$file};
      if (!defined $props) {
        my $fname = $basedir."/".$file;
        $props = load_json($fname);
        my $d = dirname($fname);
        $props->{file} =~ s/^/$d\//;
        $$proplist{$file} = $props;
      }
      $$_{props} = $props;
    }
  }
  return \@files;
}

sub make_mix {
  my ($infile,$outfile,$do_test) = @_;

  $do_test = ($do_test//"") eq "test";
  $outfile = $do_test ? "test.avi" : $outfile;
  #$outfile //= $infile.".avi"; # or .mp3.

  die "need at least an input filename"
    unless defined $infile;
  my $basedir = dirname($infile);
  my $mixinfo = load_json($infile);

  my $starttime = $mixinfo->{starttime};
  my @specs = @{get_mix_files($mixinfo,$basedir)};
  my $nfiles = @specs;

  die "nfiles <= 1: $nfiles" if $nfiles <= 1;

# DONE: mix different numbers of audio channels and non-video audio files.
# DONE: allow stereo-mixing by positioning the parts.
# DONE: different video resolutions. -> are scaled to fit.
# FIXED: ffmpeg error "could not seek to position 0.100"

  my $resolution = $$mixinfo{resolution};
  my ($nvideos,$naudios) = (0,0);
  for (@specs) {
    my $props = $$_{props};
    my $fname = $basedir."/".$$_{file};
    #my $fname = $basedir."/".$$_[0];
    #my $entry = load_json($fname);
    for (qw(sync syncmode file)) {
      die "missing json parts" unless defined $props->{$_};
    }
    #my $d = dirname($fname);
    # FIXED: $entry may be shared, but is modified here.
    #$props->{file} =~ s/^/$d\//;
    my $info = $props->{info};
    if (!defined ($info)) {
      $info = get_avfile_info($props->{file});
      $props->{info} = $info;
    }
    $$_{info} = $info; # redundant, but convenient.
    #$$_[0] = $entry;
    $$_{do_video} = defined $info->{video} && ($$_{only}//"") ne "audio";
    $$_{do_audio} = defined $info->{audio} && ($$_{only}//"") ne "video";
    $nvideos++ if $$_{do_video};
    $naudios++ if $$_{do_audio};
    if (!defined $resolution && $$_{do_video}) {
      $resolution = [@{$info->{video}}{qw(width height)}];
    }
  }

  # DONE: support nvideos <= 1
  #die "nvideos <= 1 is not yet implemented (nvideos = $nvideos)"
  #  if $nvideos <= 1;

  my $do_video = $nvideos > 0 && ($$mixinfo{only}//"") ne "audio"
    && !(defined $outfile && $outfile =~ /\.mp3$/);
  my $do_audio = $naudios > 0 && ($$mixinfo{only}//"") ne "video";
  $nvideos = 0 if !$do_video;
  $naudios = 0 if !$do_audio;
  $outfile //= $infile.($do_video ? ".avi" : ".mp3");
  $outfile =~ s{^-}{./-};

  my $grid_aspect = $$mixinfo{grid_aspect}//1;
  # cols/rows ~= $grid_aspect <= cols/rows
  # e.g. $grid_aspect ~ 16/9 for merging vertical 3:4 videos into a horizontal 4:3 one. (256/81 ~ 3.16 for 9:16 -> 16:9)
  my $cols = ceil(sqrt($nvideos*$grid_aspect)) || 1;
  my $rows = ceil($nvideos/$cols);

  my @x_pos = map floor($_/$cols*$$resolution[0]), 0..$cols;
  my @y_pos = map floor($_/$rows*$$resolution[1]), 0..$rows;
  my @widths = map $x_pos[$_+1]-$x_pos[$_], 0..$cols-1;
  my @heights = map $y_pos[$_+1]-$y_pos[$_], 0..$rows-1;

  my $layout = join("|",map
      {
        #my $x = join("+",("w0") x ($_ % $cols)) || "0";
        #my $y = join("+",("h0") x floor($_ / $cols)) || "0";
        #$x."_".$y;
        $x_pos[$_ % $cols]."_".$y_pos[$_ / $cols];
      } 0..$nvideos-1);

  if (!defined $starttime) {
    my $minsync = undef;
    for (@specs) {
      #$minsync = $_->[0]{sync}
      #  if !defined $minsync || $minsync > $_->[0]{sync};
      $minsync = $$_{props}{sync}
        if !defined $minsync || $minsync > $$_{props}{sync};
    }
    #$starttime = -$minsync+0.1;
    $starttime = -$minsync;
  }

# Let's make the filter script a bit more systematic:
#   [$_:v] <v-input-filters > [video$_];
#   [$_:a] <a-input-filters > [audio$_];
#   [video1]...[video$n] xstack, <v-output-filters> [vout];
#   [audio1]...[audio$n] amix, <a-output-filters> [aout];
# pan="stereo|c0=$A*c0+$A*c1|c1=$B*c0+$B*c1"
# <a-input-filters> := asetpts=PTS+$delay/TB,pan="stereo|c0=$A*FC|c1=$B*FC"
# <v-input-filters> := setpts=PTS+$delay/TB,scale=$w:-2

  #my (@prefilters,$vmixfilter,$amixfilter);
  my @filters;

  my ($video_i,$audio_i) = (0,0);
  for (0..$nfiles-1) {
    my @pan = @{$specs[$_]{stereo}};
    my $start = $specs[$_]{props}{sync}+$starttime;
    my $delay = -($specs[$_]{props}{sync}+$starttime);
    my ($vid,$aud) = @{$specs[$_]{info}}{qw(video audio)};
    my ($do_vid,$do_aud) = @{$specs[$_]}{qw(do_video do_audio)};
    if ($do_video && $do_vid) {
      my @out_size = ($widths[$video_i % $cols],$heights[$video_i / $cols]);
      my @in_size = @$vid{qw(width height)};
      # what's the best solution for this?
      my $scaled_h = $out_size[0]*$in_size[1]/$in_size[0];
      # convert aspect ratio -> crop or pad?
      my $scalefilter;
      if ($scaled_h > $out_size[1]) { # too high
        #my $h = int($out_size[1]/$out_size[0]*$in_size[0]);
        $scalefilter = "scale=$out_size[0]:-1,crop=h=$out_size[1]:exact=1";
      } elsif ($scaled_h < $out_size[1]) { # too wide
        $scalefilter = "scale=-1:$out_size[1],crop=w=$out_size[0]:exact=1";
      } else {
        $scalefilter = "scale=$out_size[0]:$out_size[1]";
      }
      # special case because xstack can't handle exactly one video and we don't do any additional output filtering.
      my $vout = $nvideos == 1 ? "[vout]" : "[video$video_i]";
      push @filters,
        "[$_:v] trim=$start,setpts=PTS-STARTPTS,$scalefilter $vout";
      $video_i++;
    }
    if ($do_audio && $do_aud) {
      my $c = $aud->{channels};
      $c = 2 if $c > 2;
      $_ /= $c for @pan;
      my $panstr = "stereo";
      for my $i (0,1) {
        $panstr.="|c$i=".join("+",map "$pan[$i]*c$_", 0..$c-1);
      }
      push @filters,
        "[$_:a] atrim=$start,asetpts=PTS-STARTPTS,pan=$panstr [audio$audio_i]";
      $audio_i++;
    }
  }
  if ($video_i != $nvideos || $audio_i != $naudios) {
    die "Bug: miscount of videos/audios ($video_i/$nvideos, $audio_i/$naudios)";
  }

  my @fileargs = map {
#    my $entry = $$syncdb{$$_[0]};
#    die "file \"$$_[0]\" not in database" unless defined $entry;
#    for (qw(sync syncmode file)) {
#      die "missing json parts" unless defined $entry->{$_};
#    }
#    ("-ss",$$syncdb{$$_[0]}{sync},"-i",$$syncdb{$$_[0]}{file})
     #("-ss",$$_[0]{sync}+$starttime,"-i",$$_[0]{file})
     #("-itsoffset",-($$_[0]{sync}+$starttime),"-i",$$_[0]{file})
     ("-i",$$_{props}{file})
    } @specs;
  #my $a_inspec = join("",map "[$_:a]", 0..$nfiles-1);
  #my $v_inspec = join("",map "[$_:v]", 0..$nfiles-1);
  my $a_inspec = join("",map "[audio$_]", 0..$naudios-1);
  my $v_inspec = join("",map "[video$_]", 0..$nvideos-1);
  my $aweights = join(" ",map $$_{weight}//1, grep $$_{do_audio}, @specs);

  my @test_args = $do_test ? qw(-t 20) : ();
  my $length = $mixinfo->{length};
  @test_args = ("-t",$length) if defined $length;

  # DONE: does the amix filter behave well with exactly one input? Yes, it does.
  if ($do_audio) {
    push @filters,
      "$a_inspec amix=inputs=$naudios:weights=$aweights:duration=longest [aout]";
  }
  # xstack can't handle stacking exactly one video.
  if ($do_video && $nvideos > 1) {
    push @filters,
      "$v_inspec xstack=inputs=$nvideos:layout=$layout [vout]";
  }
    #$nvideos == 1 ? "$v_inspec scale=iw/$cols:-2 [vout]" :
    #"$v_inspec xstack=inputs=$nvideos:layout=$layout,scale=iw/$cols:-2 [vout]";
  # DONE: filter should be given in a file or fd rather than an arg.
  my @vselect = $do_video ? qw(-map [vout] -codec:v h264) : ();
  my @aselect = $do_audio ? qw(-map [aout] -ar 48000 -codec:a mp3) : ();

  my $filterfile = File::Temp->new;
  print $filterfile join(";\n",@filters),"\n";
  $filterfile->flush;

  my @cmdline=(qw(ffmpeg -hide_banner -loglevel warning -accurate_seek -y),
     @fileargs,
     "-filter_complex_script",$filterfile->filename,
     @vselect,@aselect,
     #"-filter_complex",join(";",@filters),@vselect,@aselect,
     @test_args,$outfile);

  #print STDERR "CMD: ",join(" ",map "<$_>", @cmdline),"\n";
  do_system(@cmdline);
}

### vconductor

# FIXME: symlinks require tmp.frames and tmp.samples to be without a path.
# NOTE: This function uses mkdir, unlink, symlink and open, but their arguments
#       are fully controlled and completely ascii, so we don't need to worry.
sub vconductor {
  my ($spec,$profiledir) = @_;
  $profiledir //= "vconductor_profile";

  $profiledir = File::Spec->rel2abs($profiledir);

  ### read the profile

  my $profile = load_json($profiledir."/spec.json");
  
  for (qw(frames sample_rate audio_channels sample_format audio_offset)) {
    die "missing parameter \"$_\"" if !defined $$profile{$_};
  }
  
  my $inframes_dir = $profiledir."/frames";
  my $inframes_count = $$profile{frames};
  #my $inframes_count = 37;
  #my $inframes_count = 10;
  
  my $insamples_file = $profiledir."/beat_samples.raw";
  #"sample_beat.1-s16le-48000";
  die "unsupported sample format $$profile{sample_format}"
    unless lc($$profile{sample_format}) eq "s16le";
  
  my $sample_channels = $$profile{audio_channels};
  # actually, I can't hear the difference anyway:
  my $insamples_offset = $$profile{audio_offset};
  #my $insamples_offset = 111;
  
  my $framerate = 25;
  my $samplerate = $$profile{sample_rate};
  my $beat_samples = slurp($insamples_file);
  my $beat_samples_count = length($beat_samples)/$sample_channels/2;
  
  my $tempdir = File::Temp->newdir(CLEANUP => 1);

  # FIXED: get a tempdir for that.
  my $frame_links_dir = "$tempdir/tmp.frames";
  my $samples_file = "$tempdir/tmp.samples";

  ### read the spec
  
  my ($outfile,$bpm,$starttime,$beats,$syncmode,$syncbeats,$trailtime) =
    @$spec{qw(file bpm starttime beats syncmode syncbeats trailtime)};
  $bpm //= 60;
  $beats //= 10;
  die "need an output filename" unless defined $outfile;
  $syncmode //= "twoclap";
  if (!defined $syncbeats) {
    my $n = $syncmode eq "twoclap" ? 2 : $syncmode eq "oneclap" ? 1 : 0;
    $syncbeats = [map 1.5+$_, 0..$n-1 ];
  }
  $starttime //= (@$syncbeats?$$syncbeats[-1]:0)+5;
  $trailtime //= 0;
  # TODO: support trailtime
  
  my @all_beats = (@$syncbeats,map $_*60/$bpm+$starttime, 0..$beats-1);
  
  my $frames_per_beat = 60/$bpm*$framerate;
  my $samples_per_beat = 60/$bpm*$samplerate;
  my $len = $beats*60/$bpm;
  my $nframes = $len*$framerate;
  my $nsamples = $len*$samplerate;
  my $startframes = $starttime*$framerate;
  my $startsamples = $starttime*$samplerate;

  ### prepare output

  mkdir $frame_links_dir;
  my $nextbeat = 0;
  my $lastbeat_time = -1;
  my $nextbeat_time = $all_beats[0];
  my $interbeat_time = $nextbeat_time-$lastbeat_time;
  for my $i (0..$startframes+$nframes-1) {
    my $time = $i/$framerate;
    if ($time >= $nextbeat_time) {
      $nextbeat++;
      $lastbeat_time = $nextbeat_time;
      $nextbeat_time = $all_beats[$nextbeat]//($len+$starttime+1);
      $interbeat_time = $nextbeat_time-$lastbeat_time;
    }
    my $beatpos = ($time-$lastbeat_time)/$interbeat_time;
    if ($interbeat_time > 1.5) {
      # f(0) = 0, f(1) = 1, f'(0) = m, f'(1) = m
      # f(x) = a*x^3+b*x^2+c*x+d => d ? 0 a+b+c = 1, c=m, 3*a+2*b+c = m
      # 3*a = -2*b, a = 2*(m-1), b = 3*(1-m)
      # f(x) = 2*(m-1)*x^3+3*(1-m)*x^2+m
      #  -- but probably not monotonous
      # g(x) = f(x)-x
      # g(0) = g(1) = 0, g'(0) = g'(1) = m-1>0, g'(1/2) = -1
      # g(x) = bezier([a,b,c,d,e,f])
      #      = f*(1-x)^5+5*e*(1-x)^4*x+10*d*(1-x)^3*x^2 + 10*c*(1-x)^2*x^3+...
      # g'(x) = bezier(5*[a-b,b-c,c-d,d-e,e-f])
      #  a = f = 0, -b=e=m/5, c := -d
      # g'(1/2) = bez(5*[-b,b-c,2*c,b-c,-b])(1/2) = (b*6+c*4)*(1/2)^4*5 = -1
      #   c = (m*3-8)/10
      #  -- but will eventually also give ringing due to polynomial form...
      # h(t) = 2*f((t+1)/2)-1; -h(-1)=h(1)=1, h'(-1)=h'(1)=m
      # h(t) = (tan(a*t)-a*t)*b // always monotonous, always antisymmetric
      # h'(t) = (1/cos^2(a*t)-1)*a*b
      # (tan(a)-a)*b = 1, (1/cos^2(a)-1)*a*b = m
      # b = 1/(tan(a)-a), tan^2(a)*a/(tan(a)-a) = m
      # tan^2(a)*a+m*a = tan(a)*m -- a > 0
      # subst: tan -> p(t) = x/(1-x^2), p'(t) = (1+x^2)/(1-x^2)^2, p'(0) = 1
      # h'(t) = (p'(a*t)-1)*a*b
      # (p(a)-a)*b = 1, (p'(a)-1)*a*b = m
      # (p'(a)-1)*a/(p(a)-a) = m
      # ((1+a^2)/(1-a^2)^2-1)*a/(a/(1-a^2)-a) = m
      # ((1+a^2-(1-a^2)^2)/(1-a^2)^2)/(a^2/(1-a^2)) = m
      # (3-a^2)/(1-a^2)^2*(1-a^2) = m
      # (3-a^2)/(1-a^2) = m
      # a = sqrt((3-m)/(1-m))
      my $m = $interbeat_time*2;
      if ($m > 3) {
        my $a = sqrt((3-$m)/(1-$m));
        my $b = (1-$a**2)/$a**3;
        my $x = $a*($beatpos*2-1);
        $beatpos = (($x**3/(1-$x**2))*$b+1)/2;
      } else {
        my $t = 1/$interbeat_time;
        $beatpos = $beatpos < $t/2 ? $beatpos/$t :
                   $beatpos < 1-$t/2 ? 0.5 : ($beatpos-1)/$t+1;
      }
    }
    $beatpos++ if $nextbeat % 2 == 0;
    #$beatpos += 0.5;
    #$beatpos -= 2 if $beatpos >= 2;
  
  #   my $frame = $i-$startframes;
  #   my $beatpos = $frame/$frames_per_beat+0.5;
  #   $beatpos = $beatpos-floor($beatpos/2)*2;
  #   #$beatpos = 1-$beatpos if $beatpos > 0.5;
  #   $beatpos = 0.5 if $frame <= 0;
  
    #my $ref_i = 1+floor($beatpos/2*($inframes_count-0.01));
    my $ref_i = 1+floor($beatpos/2*$inframes_count);
    #symlink sprintf("../%s/%04d.png",$inframes_dir,$ref_i),
    #        sprintf("%s/%04d.png",$frame_links_dir,$i+1);

    # These are absolute symlinks now.
    symlink sprintf("%s/%04d.png",$inframes_dir,$ref_i),
            sprintf("%s/%04d.png",$frame_links_dir,$i+1);
  }

  open (my $sample_f,">",$samples_file)
    or die "cannot open \"$samples_file\": $!";

  my $buf = "";
  my $nullsample = pack("s<",0) x $sample_channels;
  my $sample_pos = 0;
  #my $sample_pos = -$startsamples;
  #for my $i (0..$beats-1) {
  #  my $nextpos = ($i+1/2)*$samples_per_beat-$insamples_offset;
  for my $nexttime (@all_beats) {
    my $nextpos = floor($nexttime*$samplerate)-$insamples_offset;
    die "beat duration < beat file length"
      if $nextpos < $sample_pos;
    $buf .= $nullsample x ($nextpos-$sample_pos);
    $buf .= $beat_samples;
    $sample_pos = $nextpos+$beat_samples_count;
    if (length($buf) > 8192) {
      print $sample_f $buf;
      $buf = "";
    }
  }
  $buf .= $nullsample x ($nsamples+$startsamples-$sample_pos);

  print $sample_f $buf;
  close($sample_f);

  my @cmdline = (qw(ffmpeg -hide_banner -loglevel error -nostats -nostdin -y -f image2 -r),
                 $framerate,"-i",$frame_links_dir."/%04d.png",
                 qw(-ac 1 -ar),$samplerate,qw(-f s16le -i), $samples_file,
                 qw(-codec:v h264 -codec:a mp3),$outfile);

  #print STDERR "CMD: ",join(" ",map "<$_>", @cmdline),"\n";
  do_system(@cmdline);

  # handled by $tempdir
  #do_system(qw(rm -r),$frame_links_dir);
  #unlink $samples_file;
}

# make from json spec
sub make_vconductor {
  my ($specfile,$profiledir) = @_;
  my $spec = load_json($specfile);
  $$spec{file} //= $specfile.".avi";
  vconductor($spec,$profiledir);
}

# make from command line spec
sub create_vconductor {
  die "wrong number of parameters" unless @_%2 == 1 && @_ >= 3;
  my ($outfile,$bpm,$beats,%args) = @_;
  my $spec = \%args;
  my $profiledir = $$spec{profile}; # may be undef
  delete $$spec{profile};
  $$spec{file} = $outfile;
  $$spec{bpm} = $bpm;
  $$spec{beats} = $beats;
  vconductor($spec,$profiledir);
}

### update everything in a directory

sub do_ls {
  my $dirname = shift;
  utf8::encode($dirname);
  opendir(my $f, $dirname) or die "cannot read directory \"$dirname\": $!";
  my @files = readdir($f);
  closedir($f);
  utf8::decode($_) for @files;
  return @files;
}

sub update_syncs {
  my $dir = shift//".";
  my @files = do_ls($dir);
  my @syncs = grep /^.*\.syncjson$/, @files;
  for (@syncs) {
    eval {
      sync_detect($dir."/".$_,"update");
    };
    if ($@) {
      print STDERR "Warning: in sync \"$_\": $@\n";
    }
  }
}

sub get_filetime {
  my $fname = shift;
  utf8::encode($fname);
  my @stat = stat($fname);
  return @stat ? $stat[9] : undef;
}

sub update_mixes {
  my $dir = shift//".";
  my @files = do_ls($dir);
  my @mixes = grep /^mix-.*\.json$/, @files;
  # we don't want to cache stats, as we want to avoid races.
  #my %stats;
  #$stats{$_} = [stat($dir."/".$_)] for @files;
  for my $mix (@mixes) {
    eval {
      open(my $lockf,"<",$dir."/".$mix)
        or die "cannot open $mix for locking: $!";
      flock($lockf,LOCK_EX);
      my $spectime = get_filetime($dir."/".$mix);
      #my $spectime = $stats{$_}[9];
      my $spec = load_json($dir."/".$mix);
      my $outfile = $mix.".avi";
      my $outtime = get_filetime($dir."/".$outfile);
      #my $outtime = $stats{$outfile} ? $stats{$outfile}[9] : undef;
      my $needs_work = !defined $outtime || $outtime < $spectime;
      if (!$needs_work) {
        for (@{$spec->{files}}) {
          my $time = get_filetime($dir."/".$$_[0]);
          die "file $$_[0] does not exist" if !defined $time; #$stats{$$_[0]};
          #my $time = $stats{$$_[0]}[9];
          $needs_work = 1 if ($outtime < $time);
        }
      }
      if ($needs_work) {
        make_mix($dir."/".$mix);
      }
      flock($lockf,LOCK_UN);
      close($lockf);
    };
    if ($@) {
      print STDERR "Warning: in mix \"$mix\": $@\n"; 
    }
  }
}

sub create_syncjson {
  my ($fname,$outfname) = @_;
  $outfname //= ($fname =~ s{\.[^./]*$}{}r).".syncjson";
  my $d1 = dirname($outfname);
  my $d2 = dirname($fname);
  if ($d1 eq $d2) {
    $fname = basename($fname);
  } elsif ($d1 eq ".") {
    warn "Warning: embedding absolute file path"
      if $d2 =~ /^\//;
  } else {
    die "Error: making a relative path is not implemented yet."
      unless $d2 =~ /^\//;
    warn "Warning: embedding absolute file path";
  }
  store_json($outfname,{ file => $fname, syncmode => "twoclap" });
}

### dispatcher

#  command => [ "arg1 arg2",
#    "does something"],
my %documentation = (
  create_mix => [ "file_n[=weight_n]...",
    "creates a new mix of the given files and writes it to stdout"],
  make_mix => [ "infile [outfile] [test]",
    "builds the mix described in infile. builds 10 seconds to \"test.avi\" if parameter \"test\" is given"], # FIXME: use outfile instead
  sync_detect => [ "syncjsonfile [update]",
    "applies the sync-method in syncjsonfile to find the sync beat and stores it in syncjsonfile. Does not re-calculate if \"update\" is given."],
  make_vconductor => [ "specfile profiledir",
    "makes a vconductor video from a given specfile."],
  create_vconductor => [ "outfile bpm beats [key value]...",
    "makes a vconductor video with the given bpm, beats and other named arguments. In particular \"profile\" should probably be given."],
  create_syncjson => [ "mediafile [outsyncjsonfile]",
    "creates a default syncjson file for a given mediafile."],
  update_mixes => [ "[dir]",
    "updates all mixes in dir (current directory, if not given)."],
  update_syncs => [ "[dir]",
    "updates all .syncjson files in dir (current directory, if not given)."],
  help => [ "[all]|[command]...",
    "shows help for a given command"],
);

my %cmds = (
  create_mix => \&create_mix,
  make_mix => \&make_mix,
  sync_detect => \&sync_detect,
  make_vconductor => \&make_vconductor,
  create_vconductor => \&create_vconductor,
  create_syncjson => \&create_syncjson,
  update_mixes => \&update_mixes,
  update_syncs => \&update_syncs,
  help => \&help,
);

sub usage {
  my @commands = sort keys %cmds;
  print "usage: $0 <cmd> <args>\n".
    "where <cmd> is one of: ".join(", ",@commands)."\n";
}

sub help {
  my @args = @_;
  if (@args == 0) {
    usage();
  } elsif ($args[0] eq "all") {
    @args = sort keys %cmds;
  }
  for (@args) {
    my $line;
    my $doc = $documentation{$_};
    if (defined $doc) {
      $line = "  $_ ".$doc->[0]."\n      ".$doc->[1];
    } else {
      $line = defined $cmds{$_} ?
        "command $_ exists, but is sadly undocumented" :
        "command $_ does not exist";
    }
    print $line,"\n";
  }
}

for (@ARGV) {
  utf8::decode($_) or die "non-utf8 ARGV";
}
my $cmd = shift @ARGV // "help";
my $sub = $cmds{$cmd};
die "unknown command \"$cmd\"" unless defined $sub;

eval {
  $sub->(@ARGV);
};

if ($@) {
  print STDERR "Error: $@\n";
  exit 2;
}
exit 0;


