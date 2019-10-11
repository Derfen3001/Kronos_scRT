#!/usr/local/bin/Rscript --slave
#parse input

if (!suppressPackageStartupMessages(require(optparse, quietly = TRUE))) {
    install.packages("optparse", quiet = T)
    suppressPackageStartupMessages(library(optparse, quietly = TRUE))
}

options(stringsAsFactors = FALSE)

option_list = list(
    make_option(
        c("-R", "--RefGenome"),
        type = "character",
        default = NULL,
        help = "Fasta file of genome of interst",
        metavar = "character"
    ),
    make_option(
        c("-c", "--cores"),
        type = "integer",
        default = 3,
        action = 'store',
        help = "Number of cores to use. [default= %default]",
        metavar = "integer"
    ),
    make_option(
        c("-s", "--reads_size"),
        type = "integer",
        default = 40,
        action = 'store',
        help = "Lengh of the simulated reads. [default= %default bp]",
        metavar = "integer"
    ),
    make_option(
        c("-o", "--output_dir"),
        type = "character",
        default = 'output/',
        action = 'store',
        help = "Output folder. [default= %default]",
        metavar = "character"
    ),
    make_option(
        c("-i", "--index"),
        type = "character",
        action = 'store',
        help = "Bowtie 2 index",
        metavar = "character"
    ),
    make_option(
        c( "--paired_ends"),
        type = "logical",
        action = 'store_true',
        help = "Generates paired ends reads [default: %default]",
        metavar = "logical",
        default = F
    ),
    make_option(
        c( "--insert_size"),
        type = "integer",
        action = 'store',
        help = "Insert size if paired end option is used. [default: %default]",
        metavar = "integer",
        default = '200'
    ),
    make_option(
        c("--bin_size"),
        type = "integer",
        default = 20000,
        action = 'store',
        help = "Bins size. [default= %default bp]",
        metavar = "integer"
    ),
    make_option(
        c("-d","--dir_indexed_bam"),
        type = "character",
        action = 'store',
        help = "If provided parameters will be automatically estimated form the data.",
        metavar = "character"
    )
)

opt = parse_args(OptionParser(option_list = option_list),convert_hyphens_to_underscores = T)

#load needed packages
if (!suppressPackageStartupMessages(require(BiocManager, quietly = TRUE))){
    install.packages("BiocManager",quiet = T)
}

if (!suppressPackageStartupMessages(require(tidyverse, quietly = TRUE))) {
    install.packages("tidyverse", quiet = T)
    suppressPackageStartupMessages(library(tidyverse, quietly = TRUE))
}

if(!suppressPackageStartupMessages(require(DescTools, quietly = TRUE))){
    install.packages("DescTools",quiet = T)
    suppressPackageStartupMessages(library(DescTools, quietly = TRUE ))
}

if(!suppressPackageStartupMessages(require(foreach, quietly = TRUE))){
    install.packages("foreach",quiet = T)
    suppressPackageStartupMessages(library(foreach, quietly = TRUE))
}

if(!suppressPackageStartupMessages(require(doSNOW, quietly = TRUE))){
    install.packages("doSNOW",quiet = T)
    suppressPackageStartupMessages( library(doSNOW, quietly = TRUE))
}

if(!suppressPackageStartupMessages(require(Biostrings, quietly = TRUE))){
    BiocManager::install('Biostrings')
    suppressPackageStartupMessages( library(Biostrings, quietly = TRUE))
}

if(!suppressPackageStartupMessages(require(Rbowtie2, quietly = TRUE))){
    BiocManager::install('Rbowtie2')
    suppressPackageStartupMessages( library(Rbowtie2, quietly = TRUE))
}

if(!suppressPackageStartupMessages(require(Rsamtools, quietly = TRUE))){
    install.packages("Rsamtools",quiet = T)
    suppressPackageStartupMessages( library(Rsamtools))
}
if (!suppressPackageStartupMessages(require(Rsamtools, quietly = TRUE))) {
    BiocManager::install('Rsamtools')
    suppressPackageStartupMessages(library(Rsamtools, quietly = TRUE))
}
options(scipen = 9999)

# create output directory
if (str_extract(opt$output_dir,'.$')!='/'){
    opt$output_dir=paste0(opt$output_dir,'/')
}

system(paste0('mkdir -p ', opt$output_dir))

# check imputs 
if(!"RefGenome" %in% names(opt)){
    stop("Fastq file not provided. See script usage (--help)")
}

if(!"index" %in% names(opt)){
    stop("Bowtie2 indexed genome not provided. See script usage (--help)")
}

#loading reference fa
reference=readDNAStringSet(opt$RefGenome)

cl=makeCluster(opt$cores)
registerDoSNOW(cl)

if ('dir_indexed_bam' %in% names(opt)){
#sample 20 files to exstimate parameters
    list=list.files(opt$dri_indexed_mab,pattern = 'bam$')
    list=sample(list,ceiling(length(list)/20))
    parameters=foreach(i=list,.combine = 'rbind',.packages = 'Rsamtools')%dopar%{
        sapply(scanBam(paste0(opt$dri_indexed_mab,i),param=ScanBamParam(what=c('isize','qwidth')))[[1]],
                function(x) median(abs(x),na.rm = T))
    }
    
    parameters=as.tibble(parameters)%>%
        summarise(qwidth=round(median(qwidth)),
                  isize=round(median(isize)))
    
    if(parameters$isize!=0){
        opt$paired_ends=T
        opt$insert_size=parameters$isize
        opt$reads_size=parameters$qwidth
    }else{
        opt$reads_size=parameters$qwidth
    }
  
}

genome.Chromsizes = foreach(
    Chr = names(reference),
    .combine = 'rbind',
    .packages = c('Biostrings', 'foreach', 'tidyverse')
) %dopar% {
    #genome size
    genome.Chromsizes = tibble(chr = Chr,
                               size = width(reference[Chr]))
    
    # Identify reagins in wich the sequence is known
    find_known_sequences = function(x) {
        library(tidyverse)
        y = str_locate_all(x, '.[TACG]+')
        return(tibble(start = y[[1]][, 1], end = y[[1]][, 2]))
    }
    
    position = find_known_sequences(reference[Chr])
    
    #look for seeds
    if (opt$paired_ends) {
        #initialize simulated reads
        size = (2 * opt$reads_size + opt$insert_size)
        position = position %>%
            filter(end - start > size)
        
        simulated_reads_1 = foreach(i = 1:length(position$start),
                                    .combine = 'c') %do% {
                                        seq(position$start[i], position$end[i]-size, by = size)
                                    }
        simulated_reads_1 = tibble(start = unlist(simulated_reads_1),
                                   end = start + opt$reads_size) %>%
            mutate(order =  row_number())
        simulated_reads_2 = simulated_reads_1 %>%
            mutate(start = end + opt$insert_size,
                   end = start + opt$reads_size)
        
    } else{
        size = opt$reads_size
        position = position %>%
            filter(end - start > size)
        #initialize simulated reads
        simulated_reads = foreach(i = 1:length(position$start)) %do% {
            seq(position$start[i], position$end[i]-size, by = opt$reads_size)
        }
        simulated_reads = tibble(start = unlist(simulated_reads),
                                 end = start + opt$reads_size) %>%
            mutate(order =  row_number())
    }

    #recover reads and mutate them
    recover_and_mutate = function(simulated_reads, Chr_reference) {
        library(tidyverse)
        simulated_reads = tibble(
            reads = str_sub(
                Chr_reference,
                start = simulated_reads$start,
                end = simulated_reads$end - 1
            ),
            order = simulated_reads$order
        )%>%
            mutate(reads=str_remove(reads,'N'))
        
        # simulate mutations 0.1 % rate
        mutate = sample(1:length(simulated_reads$reads),
                        0.001 * length(simulated_reads$reads))
        to_mutate = simulated_reads[mutate,]
        simulated_reads = simulated_reads[-mutate,]
        
        to_mutate = to_mutate %>%
            group_by(reads) %>%
            mutate(
                len = str_length(reads),
                mutate = sample(1:40, 1),
                before = str_sub(reads, 0, mutate - 1),
                after = str_sub(reads, mutate + 1, len),
                mutate_b = str_sub(reads, mutate, mutate),
                mutated_base = ifelse(
                    mutate_b == 'A',
                    sample(c('T', 'C', 'G'), 1),
                    ifelse(
                        mutate_b == 'C',
                        sample(c('A', 'T', 'G'), 1),
                        ifelse(
                            mutate_b == 'G',
                            sample(c('A', 'T', 'C'), 1),
                            ifelse(mutate_b == 'T' ,
                                   sample(c(
                                       'A', 'C', 'G'
                                   ), 1),
                                   sample(c(
                                       'A', 'C', 'G', 'T'
                                   ), 1))
                        )
                    )
                ),
                new_seq = paste0(before, mutated_base, after),
                check = str_length(new_seq)
            ) %>%
            ungroup() %>%
            select(new_seq, order) %>%
            `colnames<-`(names(simulated_reads))
        simulated_reads = rbind(simulated_reads, to_mutate)
        return(simulated_reads)
    }
    
    if (opt$paired_ends) {
        #recover strings reads and mutate some of them
        simulated_reads_1 = recover_and_mutate(simulated_reads = simulated_reads_1,
                                               Chr_reference = reference[Chr])
        simulated_reads_2 = recover_and_mutate(simulated_reads = simulated_reads_2,
                                               Chr_reference = reference[Chr])
        #calculate reverse complement for PE
        rev_com = function(x) {
            library(tidyverse)
            dict = list(
                A = 'T',
                `T` = 'A',
                C = 'G',
                G = 'C',
                N = 'N'
            )
            x = str_extract_all(x, '.')
            x = unlist(lapply(x , function(x)
                paste0(
                    sapply(rev(x), function(x)
                        dict[[x]], simplify = T),
                    collapse = ''
                )))
            return(x)
        }
        
        simulated_reads_2 = simulated_reads_2 %>%
            mutate(reads = rev_com(reads))
    } else{
        #recover strings reads and mutate some of them
        simulated_reads = recover_and_mutate(simulated_reads = simulated_reads,
                                             Chr_reference = reference[Chr])
    }
    
    #reshape reads for the fastq file
    reshape_and_save = function(simulated_reads, file,Chr) {
       simulated_reads %>%
            arrange(order)%>%
            `colnames<-`(c('2','order') )%>%
            mutate(
                n=str_count(`2`),
                `1` = paste0('@read', 1:n(),Chr),
                `3` = '+',
                `4` = unlist(lapply(n, function(x) paste0(rep('D', x), collapse = '')))
            ) %>%
            select(-n)%>%
            gather('pos', 'towrite', -order) %>%
            arrange(order, pos) %>%
            select(towrite) %>%
            write_delim(path = file,
                        col_names = F)
        return(0)
    }
    
    if (opt$paired_ends) {
        #save fastq files
        reshape_and_save(
            simulated_reads_1,
            file = paste0(
                opt$output_dir,
                basename(opt$index),
                Chr,
                '_simulated_reads_1.fq'
            ),
            Chr=Chr
        )
        reshape_and_save(
            simulated_reads_2,
            file = paste0(
                opt$output_dir,
                basename(opt$index),
                Chr,
                '_simulated_reads_2.fq'
            ),
            Chr=Chr
        )
        
    } else{
        #save fastq file
        reshape_and_save(
            simulated_reads,
            file = paste0(
                opt$output_dir,
                basename(opt$index),
                Chr,
                '_simulated_reads.fq'
            ),
            Chr=Chr
        )    #remove from memory
        rm('simulated_reads')
    }
    genome.Chromsizes
}

stopCluster(cl)

if(opt$paired_ends){
    #merge files
    system(paste0('cat ',
        opt$output_dir,
        '*_simulated_reads_2.fq > ', opt$output_dir,
        basename(opt$index),
        '_simulated_reads_2.fq; cat ',
        opt$output_dir,
        '*_simulated_reads_1.fq > ', opt$output_dir,
        basename(opt$index),
        '_simulated_reads_1.fq'
    ))
    system(paste0('rm ',opt$output_dir, basename(opt$index),'chr*_simulated_reads_1.fq'))
    system(paste0('rm ',opt$output_dir, basename(opt$index),'chr*_simulated_reads_2.fq'))
    #align with bowtie2
    bowtie2(
        bt2Index = opt$index,
        samOutput = paste0(opt$output_dir, basename(opt$index), '_simulated_reads.sam'),
        seq1 = paste0(opt$output_dir, basename(opt$index), '_simulated_reads_1.fq'),
        seq2 = paste0(opt$output_dir, basename(opt$index), '_simulated_reads_2.fq'),
        ... = paste0('-k 1 --phred33 --ignore-quals -p ', opt$cores),
        overwrite=TRUE
    )
    
    # remove from hd simulated_reads.fq
    system(paste0('rm ',opt$output_dir, basename(opt$index),'_simulated_reads_1.fq'))
    system(paste0('rm ',opt$output_dir, basename(opt$index),'_simulated_reads_2.fq'))
    
}else{
    #merge files
    system(paste0('cat ',
                  opt$output_dir,
                  '*_simulated_reads.fq > ', opt$output_dir,
                  basename(opt$index),
                  '_simulated_reads.fq'
    ))
    
    system(paste0('rm ',opt$output_dir, basename(opt$index),'chr*_simulated_reads.fq'))
    #align with bowtie2
    suppressMessages(bowtie2(
        bt2Index = opt$index,
        samOutput = paste0(opt$output_dir, basename(opt$index), '_simulated_reads.sam'),
        seq1 = paste0(opt$output_dir, basename(opt$index), '_simulated_reads.fq'),
        ... = paste0('-k 1 --phred33 --ignore-quals -p ', opt$cores),
        overwrite=TRUE
    ))
    
    # remove from hd simulated_reads.fq
    system(paste0('rm ',opt$output_dir, basename(opt$index),'_simulated_reads.fq'))
}

# calculate bins
dir.bam<-asBam( paste0(opt$output_dir, basename(opt$index), '_simulated_reads.sam'))
system(paste0('rm ',opt$output_dir, basename(opt$index),'_simulated_reads.sam'))

if(opt$paired_ends){
    param1 <- ScanBamParam(what=c('rname','pos','isize','mapq'),
                           flag=scanBamFlag(hasUnmappedMate = T,isUnmappedQuery = F))
    param2 <- ScanBamParam(what=c('rname','pos','isize','mapq','mrnm'),
                           flag=scanBamFlag(isPaired = T,isUnmappedQuery = F))
    bins = rbind(
        as.data.frame(scanBam(dir.bam, param = param1)) %>%
            filter(mapq >= 30) %>%
            select('rname', 'pos') %>%
            `colnames<-`(c('chr', 'pos')) %>%
            mutate(read = 1),
        as.data.frame(scanBam(dir.bam, param = param2)) %>%
            filter(mapq >= 30) %>%
            mutate(read = ifelse(rname == mrnm &
                                     abs(isize) < opt$bin_size, 0.5, 1)) %>%
            select('rname', 'pos', 'read') %>%
            `colnames<-`(c('chr', 'pos', 'read'))
    )%>%
        drop_na()
    #parameter used to estiamte mappability th
    theoretical_reads = opt$bin_size/(2 * opt$reads_size + opt$insert_size)

}else{
    param <- ScanBamParam(what=c('rname','pos','mapq'),
                          flag=scanBamFlag(isUnmappedQuery = F))
    
    bins =as.data.frame(scanBam(dir.bam,param=param))%>%
        filter(mapq >= 30)%>%
        mutate(read=1)%>%
        select('rname', 'pos', 'read')%>%
        `colnames<-`(c('chr', 'pos','read'))
    
    #parameter used to estiamte mappability th
    theoretical_reads = opt$bin_size/opt$reads_size
    
}


bins = foreach (Chr = genome.Chromsizes$chr,
                .combine = 'rbind',
                .packages = 'tidyverse') %do% {
                    size = genome.Chromsizes$size[genome.Chromsizes$chr == Chr]
                    bins_chr = tibble(chr = Chr,
                                      start = seq(0, size, by = opt$bin_size)) %>%
                        mutate(end = lead(start, n = 1, default =  size))
                    ## calculate reads per bin Selected reads
                    reads_proper <- bins$pos[bins$chr == Chr &
                                                 bins$read == 0.5 ]
                    reads_notproper <- bins$pos[bins$chr == Chr &
                                                    bins$read == 1]
                    if (length(reads_proper)!=0) {
                        reads_proper[reads_proper <= 0] <- 1
                        reads_proper <-
                            hist(reads_proper,
                                 breaks =  c(1, bins_chr$end),
                                 plot = F)
                        reads_proper <-
                            reads_proper$counts / 2
                    }
                    if (length(reads_notproper)!=0) {
                        reads_notproper[reads_notproper <= 0] <- 1
                        reads_notproper <-
                            hist(reads_notproper,
                                 breaks =  c(1, bins_chr$end),
                                 plot = F)
                        reads_notproper <-
                            reads_notproper$counts
                    }
                    if (length(reads_proper)!=0 &
                        length(reads_notproper)!=0) {
                        reads = reads_notproper + reads_proper
                    } else if (length(reads_proper)!=0 &
                               length(reads_notproper)==0) {
                        reads = reads_proper
                    } else if (length(reads_proper)==0 &
                               length(reads_notproper)!=0) {
                        reads = reads_notproper
                    } else{
                        reads = 0
                    }
                    ## Concatenate
                    bins_chr %>%
                        mutate(reads = reads)
                }

bins=bins%>%
    mutate(mappability=reads/theoretical_reads,
           mappability_th=ifelse(
               mappability >= 0.8,T,F
           ))%>%
    group_by(chr)%>%
    select(chr,start,end,mappability,mappability_th)

#delete file
system(paste0('rm ',opt$output_dir, basename(opt$index), '_simulated_reads.bam*'))

#calculate gc % peer bin
cl=makeCluster(opt$cores)
registerDoSNOW(cl)

bins=foreach(i=unique(bins$chr),.combine = 'rbind', .packages =c('Biostrings','tidyverse') )%dopar%{
    bins%>%
        filter(chr==i)%>%
        mutate(
            seq=str_sub(string =  reference[names(reference)==i],start=start+1, end=end),
            gc_frequency=str_count(seq,'G|C')/str_length(seq)
        )%>%
        select(-seq)
}

stopCluster(cl)

bins=bins %>%
    mutate(type=ifelse(opt$paired_ends,'PE','SE'))

#write bisns with info
write_tsv(bins, paste0(opt$output_dir, basename(opt$index), '_bins_',ifelse(opt$paired_ends,'PE','SE'),'.tsv'))
