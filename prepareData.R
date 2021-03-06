################################################################################
# prepareData.R
# 
# The data used in this project can be found at:
# https://d396qusza40orc.cloudfront.net/dsscapstone/dataset/Coursera-SwiftKey.zip
#
# On my 8-year-old Dell Precision T3500 with a Xeon 3.33 GHz 6-core 
# hyperthreaded processor, 24 GB of RAM, and a WDC WD2002FAEX-007BA0 hard drive
# running under Kubuntu 16.04.3 linux, the runtimes were:
#     02h:35m:42s to process the train data
#     00h:11m:23s to process the test data
#
# Resources used in creating this code:
# https://github.com/rstudio/cheatsheets/raw/master/quanteda.pdf
# https://s3.amazonaws.com/assets.datacamp.com/blog_assets/datatable_Cheat_Sheet_R.pdf
# https://github.com/lgreski/datasciencectacontent/blob/master/markdown/capstone-ngramComputerCapacity.md
# https://www.coursera.org/learn/data-science-project/discussions/forums/bXKqKZfYEeaRew5BAmrkbw/threads/dW1Z5sKMEeeTyArhA0ZGig

library(data.table)
library(doParallel)
library(quanteda)


source("delta_t.R")
source("tokenizer.R")

# Set seed for reproducability
set.seed(222)

################################################################################
# Generic function for parallelizing any task (when possible)
# Input:
#    task
#        function to parallelize
#    ...
#        arguments for task
# Output:
#        output of task with arguments ...
#
# Credit for this function goes to Eric Rodriguez
# http://rstudio-pubs-static.s3.amazonaws.com/169109_dcd8434e77bb43da8cf057971a010a56.html
parallelizeTask <- function(task, ...) {
    
    # Calculate the number of cores
    ncores <- detectCores() - 1
    # Initiate cluster
    cl <- makeCluster(ncores)
    registerDoParallel(cl)
    #print("Starting task")
    r <- task(...)
    #print("Task done")
    stopCluster(cl)
    
    return(r)
}

################################################################################
# Given a zip archive and pattern matching files to be extracted, this function
# reads all matching files and concatenates them. It then shuffles the data, 
# and splits it into train and test sets.
# Input:
#    zip_file
#        name of zip archive with path relative to the directory of 
#        prepareData.R
#    pattern
#        a regex pattern of files to extract from the zip file
# Output:
#        a list containing train data (element 1) and test data (element 2)
getData <- function(zip_file, pattern) {
    
    # Create temp directory and extract files from zip archive
    td <- tempdir()
    
    # Get list of files to extract from the archive based on provided pattern
    all_files <- unzip(zip_file, list=TRUE, exdir=td)
    mask <- grepl(pattern, all_files$Name)
    files_to_extract <- all_files[mask, ]
    
    # Reformat Length column to be more meaningful
    files_to_extract$Length <- round(files_to_extract$Length / 2^20, 4)
    names(files_to_extract)[names(files_to_extract) == "Length"] <- "Size_Mb"
    
    # Inform user of files to be extracted
    print(paste0(
        "Extracting these files from archive '", zip_file, 
        "' with pattern matching '", pattern, "':"
    ))
    print(files_to_extract)
    
    # Extract the files
    extracted_files <- unzip(zip_file, files_to_extract$Name, exdir=td)
    
    # Initialize output
    dat <- NULL
    i <- 1
    
    # Loop over extracted files
    for(next_file in extracted_files) {
        # Read the next extracted file
        txt <- readLines(con=next_file, encoding="UTF-8", skipNul=TRUE)
        
        print(paste0(
            files_to_extract$Name[i], " contains ", length(txt), " lines")
        )
        
        # Concatenate data
        dat <- c(dat, txt)
        
        i <- i + 1
    }
    
    # Delete extracted files
    unlink(extracted_files)
    
    print(paste0(
        "Extracted data has ", length(dat), " lines and occupies ", 
        round(object.size(dat) / 2^20, 4), " Mb of memory"
    ))
    
    # Shuffle data
    dat <- dat[sample(seq(length(dat)))]
    
    # Split data into train and train sets
    # We retain 98% of the data for train because there are millions of rows,
    # and 2% is more than adequate to validate
    train_frac <- 0.98
    
    print(paste0(
        "Splitting data in train/test sets; fraction retained in train = ", 
        train_frac
    ))
    
    smp_size <- floor(train_frac * length(dat))
    
    inTrain <- sample(seq_len(length(dat)), size=smp_size)
    
    train <- dat[inTrain]
    test <- dat[-inTrain]
    
    return(list(train=train, test=test))
}

################################################################################
# Given a number of lines in an input text file, this function creates an
# index to split the file into chunks, to aid in processing large files. The
# chunk size is hard-coded here.
# Input:
#    max_idx
#        the number of lines in the fule (i.e., the max index number)
# Output:
#        a sequence (integer vector) from 0 to max_idx, by chunk_size
getIdx <- function(max_idx) {
    
    # Chunk sizes of 10^5 rows are small enough not to overwhelm the memory
    # and processing constraints of most modern computers.
    chunk_size <- min(100000L, max_idx)
    idx <- seq(0L, max_idx, by=chunk_size)
    idx[length(idx)] <- as.integer(max_idx)
    
    return(idx)
}

################################################################################
# This function breaks input raw text data dat into chunks as specified in idx,
# generates 1-grams, 2-grams, ..., Nmax-grams from each chunk, and then saves
# the chunks to disk.
# Input:
#    dat
#        character vector of raw input data. Each element may contain multiple
#        sentences.
#    idx
#        an integer vector from 0 to length(dat)
#    Nmax
#        maximum size of Ngrams to create
#    train
#        TRUE for train data, FALSE for test
# Output:
#        none (data saved to disk and status messages printed to console)
analyzeChunks <- function(dat, idx, Nmax, train) {
    
    if (train == TRUE) {
        # If train, set concatenator to "_" and folder fname to 'train'
        concatenator <- "_"
        fname <- "train"
    } else {
        # If test, set set concatenator to " " and folder fname to 'test'
        concatenator <- " "
        fname <- "test"
    }
    
    # Loop over the values of idx: i
    for(i in 1:(length(idx)-1)) {
        print(paste0("Analysing chunk ", i, " of ", length(idx)-1))
        
        # Chunk data:
        # Each chuck i starts at index idx[i]+1 and ends at index idx[i+1]
        qcorpus <- corpus(dat[(idx[i]+1):idx[i+1]])
        sentences <- parallelizeTask(makeSentences, qcorpus)
        
        # Loop over Ngram size: j
        # Make sure directories ../data, ../data/fname/chunks, 
        # ../data/fname/pruned, and ../data/fname/total all exist
        for (j in 1:Nmax) {
            tic <- Sys.time()
            
            # Construct j-grams
            ngram <- parallelizeTask(makeTokens, sentences, j, concatenator)
            
            # Construct document-feature matrix from ngrams
            ngram_dfm <- parallelizeTask(dfm, ngram)
            
            # Collapse ngram_dfm into a data.table with columns ngram and count,
            # keyed on ngram, creating chunk i of j-grams
            dts <- data.table(
                ngram=featnames(ngram_dfm),
                count=as.integer(colSums(ngram_dfm)),
                key="ngram"
            )
            
            # Save this chunk to disk as '../data/fname/chunks/dts_j_i.rda'
            file_name <-
                paste0("../data/", fname, "/chunks/dts_", j, "_", i, ".rda")
            
            save(dts, file=file_name)
            
            # Remove objects created in this iteration to release memory
            # TODO: Research: Is this step neccessary or effectual?
            rm(list=c("ngram", "ngram_dfm", "dts"))
            
            toc <- Sys.time()

            print(paste0("Constructed ", j, "-gram; Saved at: ", file_name,
                         "; ", delta_t(tic, toc))
            )
        }
    }
}

################################################################################
# This function combines the previously-generated Ngram chunks into total
# Ngrams, and then saves the chunks to disk. It then prunes very low-frequency
# terms from the Ngrams, splits the pruned Ngrams into X and y, and saves the 
# pruned Ngrams to disk.
# Input:
#    idx
#        an integer vector from 0 to length(dat)
#    Nmax
#        maximum size of Ngrams to create
#    train
#        TRUE for train data, FALSE for test
# Output:
#        none (data saved to disk and status messages printed to console)
combineChunks <- function(idx, Nmax, train) {
    
    if (train == TRUE) {
        # If train, set folder fname to 'train'
        fname <- "train"
    } else {
        # If test, set folder fname to 'test'
        fname <- "test"
    }
    
    # Loop over Ngram size: j
    for (j in 1:Nmax) {
        print(paste0("Combining ", j, "-grams"))
        
        # Initialize output
        out_dts <- NULL
        
        # Loop over the values of idx: i
        for(i in 1:(length(idx)-1)) {
            print(paste0("Combining chunk ", i, " of ", length(idx)-1))
            
            # Load 'dts_j_i.rda' (j-grams, chunk i) from disk
            load(file=paste0("../data/", fname, "/chunks/dts_", j, "_", i, 
                             ".rda"))
            
            # Combine dts for (j, i) with output, and sum any identical ngrams
            out_dts <- 
                rbindlist(
                    list(out_dts, dts)
                )[, lapply(.SD, sum, na.rm=TRUE), by=ngram]
        }
        
        # Rename output
        dts <- out_dts
        rm(list=c("out_dts"))
        
        setkey(dts, ngram)
        
        # Save 'dts_total_j.rda' to disk
        file_name <-
            paste0("../data/", fname, "/total/dts_total_", j, ".rda")
        
        save(dts, file=file_name)
        
        print(paste0("Saved ", file_name))
        
        # Prune Ngrams
        # Ngram frequencies follow Zipf's Law, so there's a relatively small
        # number of entries with large counts. Most of the rows consist of very
        # small counts, so we can achieve significant memory savings by
        # truncating our Ngram tables to include only those entries with a count
        # larger than 4. Don't prune the test data, though, because that will
        # skew accuracy by filtering out low-frequency terms.
        if (train == TRUE) {
            dts <- dts[count > 4]
        }
        
        # Split Ngrams up into input (X) and prediction (y)
        print("Splitting Ngrams into X and y")
        
        if (train == TRUE) {
            spl <- "_"
        } else {
            spl <- " "
        }
        
        if (j == 1) {
            dts <- dts[, ':=' (
                X="",
                y=ngram
            ), by=ngram]
        } else {
            dts <- dts[, ':=' (
                X=paste(
                    head(strsplit(ngram, split=spl)[[1]], j-1),
                    collapse=spl
                ),
                y=tail(strsplit(ngram, split=spl)[[1]], 1)
            ), by=ngram]
        }
        
        # Original ngram column not needed and takes up a lot of memory
        dts$ngram <- NULL
        
        setkey(dts, X, y)
        
        # Save 'dts_pruned_j.rda' to disk
        file_name <-
            paste0("../data/", fname, "/pruned/dts_pruned_", j, ".rda")
        
        save(dts, file=file_name)

        print(paste0("Saved ", file_name))
        
        # Remove unneeded object to reclaim memory
        rm(list=c("dts"))
    }
}

################################################################################
# This is the main function to call the other functions to prepare the data.
# Input:
#    train
#        TRUE for train data, FALSE for test
# Output:
#        none (data saved to disk and status messages printed to console)
prepareData <- function(train=TRUE) {
    
    tic <- Sys.time()
    
    # Maximum size of Ngrams
    Nmax <- 5
    
    # To save time, only call getData the first time we attempt analysis, and
    # then save the separated train and test sets to disk.
    if(file.exists("../data/dat.rda")) {
        print("Loading dat.rda")
        load("../data/dat.rda")
    } else {
        zip_file <- "../Coursera-SwiftKey.zip"
        pattern <- "en_US.*.txt"
        
        dat <- getData(zip_file, pattern)
        save(dat, file="../data/dat.rda")
    }
    
    if (train == TRUE) {
        # If train, set dat to train data and folder fname to 'train'
        dat <- dat$train
        fname <- "train"
    } else {
        # If test, set dat to test data and folder fname to 'test'
        dat <- dat$test
        fname <- "test"
    }
    
    print(paste0("Set output directory to '", fname, "'"))
    
    idx <- getIdx(length(dat))
    
    analyzeChunks(dat, idx, Nmax, train)
    
    combineChunks(idx, Nmax, train)
    
    # Package our Ngrams into a single list to make loading simpler
    print("Packaging Ngrams into single list")
    
    # Initialize output
    dts_list <- vector("list", Nmax)
    
    # Loop over Ngram size: i
    for (i in 1:Nmax) {
        load(paste0("../data/", fname, "/pruned/dts_pruned_", i, ".rda"))
        
        # Set the key to (X, y)
        setkey(dts, X, y)
        
        dts_list[[i]] <- dts
        rm(list=c("dts"))
    }
    
    # Rename output
    dts <- dts_list
    rm(list=c("dts_list"))
    
    file_name <- paste0("../data/", fname, "/dts.rda")
    save(dts, file=file_name)
    
    print(paste0("Saved ", file_name))
    
    toc <- Sys.time()

    print(paste0("Done! ", delta_t(tic, toc)))
}