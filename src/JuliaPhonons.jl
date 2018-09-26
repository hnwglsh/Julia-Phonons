module JuliaPhonons

export atomicmass
export read_POSCAR, read_meshyaml
export output_animated_xyz, output_conflated_xyz, decompose_eigenmode_atomtype, gnuplot_header, decompose_eigenmode_atom_contributions

import YAML

# This would be better in a general library!
atomicmass = Dict{AbstractString,Float64}(
"H"=>1.00794, "C" => 12.01, "N" => 14.01, "S" => 32.07, "Zn" => 65.38, 
"I" => 126.9, "Br" => 79.904, "Cl" => 35.45,
"Cd" => 112.41, "Te"  => 127.60,
"Ga" => 69.72, "As" => 74.9216,
"Cs" => 132.0, "Pb" => 207.2)
#Zn is actually Sn; stupid work-around for Pymol seeing 'Sn' as 'S'
#The initial test cases which I am covering, are phonons of CH3NH3.PbI3 and SnS

type POSCARtype
    lattice # 3x3 array of lattice vectors
    volume::Float64 # Calculated from lattice vectors; units Angstrom^3
    natoms::Int
    species
    speciescount
    atomnames
    positions
    supercell
end
POSCARtype() = POSCARtype([],0.0,0,[],[],[],[],[]) #Eeek!

"""
 read_POSCAR(f::IOStream;expansion=[1,1,1])

 Reads in VASP POSCAR format to extract lattice vectors, and species/speciescount list. 
 Also generates a set of supercell expansion vectors, defaulting to just the unitcell.
"""
function read_POSCAR(f::IOStream;expansion=[1,1,1])
# Native VASP POSCAR reader
    P=readdlm(f)
    POSCAR=POSCARtype() # Initialise custom type

    POSCAR.lattice=[ P[l,f]::Float64 for l=3:5,f=1:3 ] #Lattice 3x3 coordinates
    POSCAR.lattice*=P[2,1]::Float64 #Lattice scaling factor

    POSCAR.volume=dot(vec(POSCAR.lattice[1,:]),cross(vec(POSCAR.lattice[2,:]),vec(POSCAR.lattice[3,:]))) # Quite verbose, but this is just V=a.bxc
    
    println(STDERR,POSCAR.lattice)
    println(STDERR,"Volume: ",POSCAR.volume)

    POSCAR.species=[ P[6,f] for f=1:length(P[7,:]) ]
    POSCAR.speciescount=[ P[7,f]::Int for f=1:length(P[7,:]) ]
    POSCAR.natoms=sum(POSCAR.speciescount)
    println(STDERR,POSCAR.species)
    println(STDERR,"POSCAR.natoms: ",POSCAR.natoms)
    POSCAR.positions=[ P[l,f]::Float64 for l=9:8+POSCAR.natoms,f=1:3 ]
# The following is probably overkill, but reads the VASP atom formats + expands
# into a one dimensional string vector 
#     species:    C    N    H    Pb   I
#     speciescount:   1     1     6     1     3
    POSCAR.atomnames=AbstractString[]
    for (count,specie) in zip(POSCAR.speciescount,POSCAR.species)
        for i=1:count push!(POSCAR.atomnames,specie) end
    end
    println(STDERR,POSCAR.atomnames)

    # SUPERCELL definition. Should probably be somewhere else?
    POSCAR.supercell=[ a*POSCAR.lattice[1,:] + b*POSCAR.lattice[2,:] + c*POSCAR.lattice[3,:] for a=0:expansion[1]-1,b=0:expansion[2]-1,c=0:expansion[3]-1 ] #generates set of lattice vectors to apply for supercell expansions
    println(STDERR,"supercellexpansions ==>",POSCAR.supercell)
    
    return POSCAR
end

"Reads phonopy YAML format, currently just extracting Gamma-point eigenvectors. (Or at least, it just takes the first eigenvector.)"
function read_meshyaml(f::IOStream, P::POSCARtype)
    mesh = YAML.load(f)     #Phonopy mesh.yaml file; with phonons

    eigenvectors=[] #[] # Force type for stability.
    eigenmodes=Float64[]

# Data structure looks like: mesh["phonon"][1]["band"][2]["eigenvector"][1][2][1]
# I think here, the 1 is referring to _first_ q-point (i.e. usually Gamma)
    for (eigenmode,(eigenvector,freq)) in enumerate(mesh["phonon"][1]["band"])
#    println("freq (THz) ==> ",freq[2], "\tWavenumbers (cm-1, 3sf) ==> ",freq[2]*33.36)

        realeigenvector=[ eigenvector[2][n][d][1]::Float64 for n=1:P.natoms, d=1:3 ]
        # Array comprehension to reform mesh.yaml eigv format into [n][d] shape
        realeigenvector=reshape(realeigenvector,P.natoms,3) # doesn't do anything?

        push!(eigenvectors,realeigenvector)
        push!(eigenmodes,freq[2])
    end

    return eigenvectors, eigenmodes
end

"Generates mass-weighted displacements of the modes in anim_??.xyz format.
View the resulting with Pymol for live animations."
function output_animated_xyz(POSCAR::POSCARtype, eigenmode,eigenvector,freq,steps=32)
    filename= @sprintf("anim_%03d.xyz",eigenmode)
    anim=open(filename,"w")

    for phi=0:2*pi/steps:2*pi-1e-6 #slightly offset from 2pi so we don't repeat 0=2pi frame
        # output routines to .xyz format
        @printf(anim,"%d\n\n",POSCAR.natoms*length(POSCAR.supercell)) # header for .xyz multi part files
        
        for i=1:POSCAR.natoms
# Nb: norm of eigenvector is fraction of energy of this mode, therefore you need to 
#   divide the eigenvector by sqrt(amu) - converting from Energy --> displacement
            projection=POSCAR.positions[i,:]' + eigenvector[i,:]'*sin(phi) / sqrt(atomicmass[POSCAR.atomnames[i]]) # Fractional coordinates
            projection*=POSCAR.lattice # Scale by lattice [3x3] matrix

            for supercellexpansion in POSCAR.supercell # Runs through which unit cells to print
                supercellprojection=projection+supercellexpansion'
                @printf(anim,"%s %f %f %f\n",POSCAR.atomnames[i],supercellprojection[1],supercellprojection[2],supercellprojection[3])
            end
        end
    end
    
    close(anim)
end

"Conflated overlapping phonons; a work in progress."
function output_conflated_xyz(POSCAR::POSCARtype, modecount ,eigenvectors,eigenmodes; steps=200,repeats=8, sound=false, q=[0,0,0])  
    filename= @sprintf("conflated_%03d.xyz",modecount)
    anim=open(filename,"w")

    println("Conflated animation, outputting to $filename")
    println("Eigenvectors: $eigenvectors \nEigenvalues: $eigenmodes\n")

    if sound
        println("... Experimental sound output engaged... ")
        soundname= @sprintf("conflated_%03d.raw",modecount)
        println(" Catch this with something like:  cat $soundname |  sox -r 8000 -c 1 -e mu-law -t u8 - -t ogg slow.ogg")
        soundfile=open(soundname,"w")
    end

    t=0
    for phi=0:2*pi/steps:repeats*2*pi-1e-6 #slightly offset from 2pi so we don't repeat 0=2pi frame
        phi/=eigenmodes[1] # multiply up to match frequency of first mode
        # output routines to .xyz format
        @printf(anim,"%d\n\n",POSCAR.natoms*length(POSCAR.supercell)) # header for .xyz multi part files
    
        if sound
        dt=1/8000
        T=266 #8000/30 # samples per frame
        basefrequency=256 # 256 = middle C
        for i in 1:T
            n=0
            t=t+dt # global time for generators
            for (eigenmode,eigenvector) in zip(eigenmodes,eigenvectors)
                #    volume         envelope function     waveform
                n+= eigenmode*(1/eigenmode) * sin(phi*eigenmode)^2 * sin(t*eigenmode*basefrequency) * sin(t*eigenmode*basefrequency * 3/2) #3/2 - perfect 5th
            end
            n=n+5
            n*=15 # apply volume
            c=round(Int,abs(n))
            #@printf("%f ",n)
            @printf(soundfile,"%c",c) # put out binary character
        end

        end

        for i=1:POSCAR.natoms
# Nb: norm of eigenvector is fraction of energy of this mode, therefore you need to 
#   divide the eigenvector by sqrt(amu) - converting from Energy --> displacement
            projection=POSCAR.positions[i,:]'
            
            for supercellexpansion in POSCAR.supercell # Runs through which unit cells to print
                sp=projection+supercellexpansion'/POSCAR.lattice 
                    # OK, bit crazy to use these cached real-space diffs to get back to fractional...
                # Supercell projection, in fractional coordinates (which can exceed 1)

                for (eigenmode,eigenvector) in zip(eigenmodes,eigenvectors)
                    # We're now iterating over normal modes
                    # add to this atom... weighted by 1/omega * eigenevctor * phase factor / sqrt(amu)
                    sp+= (1/eigenmode) * eigenvector[i,:]'.*
                    sin.(phi*eigenmode.+ pi*sp/q') / 
                    sqrt(atomicmass[POSCAR.atomnames[i]]) # Fractional coordinates
                end

                sp*=POSCAR.lattice # Scale by lattice [3x3] matrix; Fractional -> real coordinates

                @printf(anim,"%s %f %f %f\n",POSCAR.atomnames[i],sp[1],sp[2],sp[3])
            end
        end
    end
    
    close(anim)
end


"""
decompose_eigenmode_atomtype(POSCAR::POSCARtype,label,realeigenvector,freq)

This decomposes the modes to the proportion that the different atomtypes (i.e.
C, O, H etc.) contribute to each phonon mode, in the unit cell.

Currently it is hard coded to produce the Energy Fraction % of the mode, in
a form suitable for plotting with GNUPLOT into a colour coded bar chart.  
Output is to STDOUT.
"""
function decompose_eigenmode_atomtype(POSCAR::POSCARtype,label,realeigenvector,freq ;f=STDOUT)
    @printf(f,"Eigenmode: %d",label)
    @printf(f,"\tFreq: %.2f (THz) %03.1f (cm-1)\t",freq,freq*33.36)

    #atomiccontribution = Dict{AbstractString,Float64}("Pb"=>0.0, "Br" => 0.0, "N" => 0.0, "C" => 0.0, "H" => 0.0)
    atomiccontribution=[POSCAR.species[i]=>0.0 for i in 1:length(POSCAR.species)]
    for i=1:POSCAR.natoms
        atomiccontribution[POSCAR.atomnames[i]]+= norm(realeigenvector[i,:])
    end
   
    totallength=sum(values(atomiccontribution))
    # Now weight every object
    for contri in keys(atomiccontribution) # Surely a better way that iterating over?
        atomiccontribution[contri]/=totallength
    end

    for contri in sort(POSCAR.species, by=x->atomicmass[x],rev=true) #Heaviest first, by lookup 
        @printf(f,"%s %.4f\t",contri,atomiccontribution[contri])
    end
#    println(atomiccontribution)
#    println(sum(values(atomiccontribution)))
    @printf(f,"\n")
end

# Header line for GNUPLOT, plotting mode decompositions.
function gnuplot_header(POSCAR::POSCARtype;f=STDOUT)
    @printf(f,"Mode 1 Freq THz THz cm1 cm1 ") 
    for contri in sort(POSCAR.species, by=x->atomicmass[x],rev=true) #Heaviest first, by lookup 
        @printf(f,"%s %s\t",contri,contri)
    end
    @printf(f,"\n")
end


"""
    decompose_eigenmode_atom_contributions(POSCAR::POSCARtype,eigenmode,realeigenvector)

This outputs (to STDOUT), for each atom in the unit cell, the contribution in terms of 
displacement, energy and inverse participation ratio, for the phonon mode.
"""
function decompose_eigenmode_atom_contributions(POSCAR::POSCARtype,eigenmode,realeigenvector)
    sumE=0.0 # sum of energy fraction
    sumEsquarred=0.0 # sum of energy fraction squared
    sumd=0.0 # sum of displacements, which are got by mass-weighting: energy fraction / sqrt(a.m.u.)
    for i=1:POSCAR.natoms
        sumE+=norm(realeigenvector[i,:])
        sumEsquarred+=norm(realeigenvector[i,:])^2
        sumd+=norm(realeigenvector[i,:])/sqrt(atomicmass[POSCAR.atomnames[i]])
    end
    println("Normalising sum (Energy): ",sumE, " Normalising sum (Displacement): ",sumd)

    prE=0.0 # participation ratio, Energy
    prd=0.0 # participation ratio, displacement
    for i=1:POSCAR.natoms
        println("Mode: ",eigenmode," Atom: ",i," ",POSCAR.atomnames[i],
        "\t EnergyFraction: ",norm(realeigenvector[i,:])/sumE,
        "\t DisplacementFraction: ",(norm(realeigenvector[i,:])/sqrt(atomicmass[POSCAR.atomnames[i]]))/sumd,
        "\t PR-E: ", norm(realeigenvector[i,:])^2/sumEsquarred)

        prE+=(norm(realeigenvector[i,:])/sumE)^2
        prd+=((norm(realeigenvector[i,:])/sqrt(atomicmass[POSCAR.atomnames[i]]))/sumd)^2
    end
    println("Mode $eigenmode IPR-Energy: ",1/prE," IPR-displacement: ",1/prd)
end 

end
