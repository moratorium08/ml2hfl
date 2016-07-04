#!/bin/bash

TEST="$(ls test_modular/*.ml)"
#TEST="$(echo test_modular/{sum.ml,sum2.ml,zero.ml,mult.ml,sum_mult_mc91.ml,example1.ml,apply.ml,twice.ml,twice_cps.ml})"

LIMIT=30s

COLS="$(tput cols)"

OPTION=" -only-result -ignore-conf -modular"
for i in $TEST
do
    echo
    echo $i
    echo
    timeout $LIMIT ./mochi.opt $OPTION $i || echo 'TIMEOUT OR ERROR'
    echo
    printf "%0.s=" $(seq $(tput cols))
    echo
done
