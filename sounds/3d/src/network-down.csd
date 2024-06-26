<CsoundSynthesizer>
<CsOptions>
-o network-down.ogg
</CsOptions>
<CsInstruments>

sr = 44100
ksmps = 10
nchnls = 2
0dbfs  = 1

instr 1

imaxshake = p4
ifreq     = p5
ifreq1    = p6
ifreq2    = p7

;low amplitude
adrp dripwater .1, 0.09, 10, .9, imaxshake, ifreq, ifreq1, ifreq2 
asig clip adrp, 2, 0.9	; avoid drips that drip too loud
     outs 0*asig, asig

endin
</CsInstruments>
<CsScore>

{2 CNT 

i1 [0.1 * $CNT] 0.5 0.5 430 1000 800 

} 

e
</CsScore>
</CsoundSynthesizer>
