library(dplyr)
library(Matrix)
library(tidyr)
library(optparse)
library(data.table)

option_list <- list(
  make_option(c("-i","--input"),type="character",help="input MGATK directory",metavar="file"),
  make_option(c("-o","--output"),type="character",help="output directory to be used as input for cellbender",metavar="file"),
  make_option("--n_cells_conf_detected",type="integer",default=2,help="n_cells_conf_detected to select variable positions [%default]",metavar="integer"),
  make_option("--strand_correlation",type="double",default=.5,help="strand_correlation to select variable positions [%default]",metavar="integer"),
  make_option("--vmr",type="double",default=.001,help="vmr to select variable positions [%default]",metavar="integer")
)

opt_parser <- OptionParser(option_list = option_list)
options <- parse_args(opt_parser)

if (is.null(options$input)) {
  print_help(opt_parser)
  stop("please supply input directory",call.=FALSE)
}

if (is.null(options$output)) {
  print_help(opt_parser)
  stop("please supply output directory",call.=FALSE)
}

# copy-and-paste a few of Signac's functions for convenience

SparseRowVar <- function(x) {
  return(rowSums(x = (x - rowMeans(x = x)) ^ 2) / (dim(x = x)[2] - 1))
}

SparseMatrixFromBaseCounts <- function(basecounts, cells, dna.base, maxpos) {

  # Vector addition guarantee correct dimension
  fwd.mat <- sparseMatrix(
    i = c(basecounts$pos,maxpos),
    j = c(cells[basecounts$cellbarcode],1),
    x = c(basecounts$plus,0)
  )
  colnames(x = fwd.mat) <- names(x = cells)
  rownames(x = fwd.mat) <- paste(
    dna.base,
    seq_len(length.out = nrow(fwd.mat)),
    "fwd",
    sep = "-"
  )
  rev.mat <- sparseMatrix(
    i = c(basecounts$pos,maxpos),
    j = c(cells[basecounts$cellbarcode],1),
    x = c(basecounts$minus,0)
  )
  colnames(x = rev.mat) <- names(x = cells)
  rownames(x = rev.mat) <- paste(
    dna.base,
    seq_len(length.out = nrow(rev.mat)),
    "rev",
    sep = "-"
  )
  return(list(fwd.mat, rev.mat))
}

ReadMGATK <- function(dir, verbose = TRUE) {
  if (!dir.exists(paths = dir)) {
    stop("Directory not found")
  }
  a.path <- list.files(path = dir, pattern = "*.A.txt.gz", full.names = TRUE)
  c.path <- list.files(path = dir, pattern = "*.C.txt.gz", full.names = TRUE)
  t.path <- list.files(path = dir, pattern = "*.T.txt.gz", full.names = TRUE)
  g.path <- list.files(path = dir, pattern = "*.G.txt.gz", full.names = TRUE)

  refallele.path <- list.files(
    path = dir,
    pattern = "*_refAllele.txt*", # valid mtDNA contigs include chrM and MT
    full.names = TRUE
  )

  # The depth file lists all barcodes that were genotyped
  depthfile.path <- list.files(
    path = dir,
    pattern = "*.depthTable.txt",
    full.names = TRUE
  )

  if (verbose) {
    message("Reading allele counts")
  }
  column.names <- c("pos", "cellbarcode", "plus", "minus")
  a.counts <- read.table(
    file = a.path,
    sep = ",",
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = column.names
  )
  c.counts <- read.table(
    file = c.path,
    sep = ",",
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = column.names
  )
  t.counts <- read.table(
    file = t.path,
    sep = ",",
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = column.names
  )
  g.counts <- read.table(
    file = g.path,
    sep = ",",
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = column.names
  )

  if (verbose) {
    message("Reading metadata")
  }
  refallele <- read.table(
    file = refallele.path,
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = c("pos", "ref")
  )
  refallele$ref <- toupper(x = refallele$ref)
  depth <- read.table(
    file = depthfile.path,
    header = FALSE,
    stringsAsFactors = FALSE,
    col.names = c("cellbarcode", "mito.depth"),
    row.names = 1
  )
  cellbarcodes <- unique(x = rownames(depth))
  cb.lookup <- seq_along(along.with = cellbarcodes)
  names(cb.lookup) <- cellbarcodes

  if (verbose) {
    message("Building matrices")
  }

  maxpos <- dim(refallele)[1]
  a.mat <- SparseMatrixFromBaseCounts(
    basecounts = a.counts, cells = cb.lookup, dna.base = "A", maxpos = maxpos
  )
  c.mat <- SparseMatrixFromBaseCounts(
    basecounts = c.counts, cells = cb.lookup, dna.base = "C", maxpos = maxpos
  )
  t.mat <- SparseMatrixFromBaseCounts(
    basecounts = t.counts, cells = cb.lookup, dna.base = "T", maxpos = maxpos
  )
  g.mat <- SparseMatrixFromBaseCounts(
    basecounts = g.counts, cells = cb.lookup, dna.base = "G", maxpos = maxpos
  )

  counts <- rbind(a.mat[[1]], c.mat[[1]], t.mat[[1]], g.mat[[1]],
                  a.mat[[2]], c.mat[[2]], t.mat[[2]], g.mat[[2]])

  return(list("counts" = counts, "depth" = depth, "refallele" = refallele))
}

ProcessLetter <- function(
  object,
  letter,
  ref_alleles,
  coverage,
  stabilize_variance = TRUE,
  low_coverage_threshold = 10,
  verbose = TRUE
) {
  if (verbose) {
    message("Processing ", letter)
  }
  boo <- ref_alleles$ref != letter & ref_alleles$ref != "N"
  cov <- coverage[boo, ]

  variant_name <- paste0(
    as.character(ref_alleles$pos),
    ref_alleles$ref,
    ">",
    letter
  )[boo]

  nucleotide <- paste0(
    ref_alleles$ref,
    ">",
    letter
  )[boo]

  position_filt <- ref_alleles$pos[boo]

  # get forward and reverse counts
  fwd.counts <- GetMutationMatrix(
    object = object,
    letter = letter,
    strand = "fwd"
  )[boo, ]

  rev.counts <- GetMutationMatrix(
    object = object,
    letter = letter,
    strand = "rev"
  )[boo, ]

  # convert to row, column, value
  fwd.ijx <- summary(fwd.counts)
  rev.ijx <- summary(rev.counts)

  # get bulk coverage stats
  bulk <- (rowSums(fwd.counts + rev.counts) / rowSums(cov))
  # replace NA or NaN with 0
  bulk[is.na(bulk)] <- 0
  bulk[is.nan(bulk)] <- 0

  # find correlation between strands for cells with >0 counts on either strand
  # group by variant (row) and find correlation between strand depth
  both.strand <- data.table(cbind(fwd.ijx, rev.ijx$x))
  both.strand$i <- variant_name[both.strand$i]
  colnames(both.strand) <- c("variant", "cell_idx", "forward", "reverse")

  cor_dt <- suppressWarnings(expr = both.strand[, .(cor = cor(
    x = forward, y = reverse, method = "pearson", use = "pairwise.complete")
  ), by = list(variant)])

  # Put in vector for convenience
  cor_vec_val <- cor_dt$cor
  names(cor_vec_val) <- as.character(cor_dt$variant)

  # Compute the single-cell data
  mat <- (fwd.counts + rev.counts) / cov
  rownames(mat) <- variant_name
  # set NAs and NaNs to zero
  mat@x[!is.finite(mat@x)] <- 0

  # Stablize variances by replacing low coverage cells with mean
  if (stabilize_variance) {
    idx_mat <- which(cov < low_coverage_threshold, arr.ind = TRUE)
    idx_mat_mean <- bulk[idx_mat[, 1]]
    ones <- 1 - sparseMatrix(
      i = c(idx_mat[, 1], dim(x = mat)[1]),
      j = c(idx_mat[, 2], dim(x = mat)[2]),
      x = 1
    )
    means_mat <- sparseMatrix(
      i = c(idx_mat[, 1], dim(x = mat)[1]),
      j = c(idx_mat[, 2], dim(x = mat)[2]),
      x = c(idx_mat_mean, 0)
    )
    mmat2 <- mat * ones + means_mat
    variance <- SparseRowVar(x = mmat2)
  } else {
    variance <- SparseRowVar(x = mat)
  }
  detected <- (fwd.counts >= 2) + (rev.counts >= 2)

  # Compute per-mutation summary statistics
  var_summary_df <- data.frame(
    position = position_filt,
    nucleotide = nucleotide,
    variant = variant_name,
    vmr = variance / (bulk + 0.00000000001),
    mean = round(x = bulk, digits = 7),
    variance = round(x = variance, digits = 7),
    n_cells_conf_detected = rowSums(x = detected == 2),
    n_cells_over_5 = rowSums(x = mat >= 0.05),
    n_cells_over_10 = rowSums(x = mat >= 0.10),
    n_cells_over_20 = rowSums(x = mat >= 0.20),
    strand_correlation = cor_vec_val[variant_name],
    mean_coverage = rowMeans(x = cov),
    stringsAsFactors = FALSE,
    row.names = variant_name
  )
  return(var_summary_df)
}

GetMutationMatrix <- function(object, letter, strand) {
  keep.rows <- paste(
    letter,
    seq_len(length.out = nrow(x = object) / 8),
    strand,
    sep = "-"
  )
  return(object[keep.rows, ])
}

ComputeTotalCoverage <- function(object, verbose = TRUE) {
  if (verbose) {
    message("Computing total coverage per base")
  }
  rowstep <- nrow(x = object) / 8
  mat.list <- list()
  for (i in seq_len(length.out = 8)) {
    mat.list[[i]] <- object[(rowstep * (i - 1) + 1):(rowstep * i), ]
  }
  coverage <- Reduce(f = `+`, x = mat.list)
  coverage <- as.matrix(x = coverage)
  rownames(x = coverage) <- seq_along(along.with = rownames(x = coverage))
  return(coverage)
}

IdentifyVariants <- function(
  object,
  refallele,
  stabilize_variance = TRUE,
  low_coverage_threshold = 10,
  verbose = TRUE,
  ...
) {
  coverages <- ComputeTotalCoverage(object = object, verbose = verbose)
  a.df <- ProcessLetter(
    object = object,
    letter = "A",
    coverage = coverages,
    ref_alleles = refallele,
    stabilize_variance = stabilize_variance,
    low_coverage_threshold = low_coverage_threshold,
    verbose = verbose
  )
  t.df <- ProcessLetter(
    object = object,
    letter = "T",
    coverage = coverages,
    ref_alleles = refallele,
    stabilize_variance = stabilize_variance,
    low_coverage_threshold = low_coverage_threshold,
    verbose = verbose
  )
  c.df <- ProcessLetter(
    object = object,
    letter = "C",
    coverage = coverages,
    ref_alleles = refallele,
    stabilize_variance = stabilize_variance,
    low_coverage_threshold = low_coverage_threshold,
    verbose = verbose
  )
  g.df <- ProcessLetter(
    object = object,
    letter = "G",
    coverage = coverages,
    ref_alleles = refallele,
    stabilize_variance = stabilize_variance,
    low_coverage_threshold = low_coverage_threshold,
    verbose = verbose
  )
  return(rbind(a.df, t.df, c.df, g.df))
}

tmp <- ReadMGATK(file.path(options$input))
variable.sites <- IdentifyVariants(tmp$counts, refallele = tmp$refallele)
high.conf <- subset(variable.sites, subset = (n_cells_conf_detected >= options$n_cells_conf_detected & strand_correlation >= options$strand_correlation & vmr > options$vmr))

var.pos <- high.conf %>%
  dplyr::mutate(pos1=gsub('([0-9]*)([ACGT])>([ACGT])','\\2-\\1-fwd',variant),
                pos2=gsub('([0-9]*)([ACGT])>([ACGT])','\\3-\\1-fwd',variant),
                pos3=gsub('([0-9]*)([ACGT])>([ACGT])','\\2-\\1-rev',variant),
                pos4=gsub('([0-9]*)([ACGT])>([ACGT])','\\3-\\1-rev',variant)) %>% 
  dplyr::select(pos1,pos2,pos3,pos4) %>% 
  gather(p,pos) %>% 
  dplyr::pull(pos)

write.table(var.pos,file.path(options$output,'genes.tsv'),
            col.names=FALSE,row.names=FALSE,quote=FALSE)
writeMM(tmp$counts[var.pos,],file.path(options$output,'matrix.mtx'))
write.table(colnames(tmp$counts),file.path(options$output,'barcodes.tsv'),
            row.names=FALSE,col.names=FALSE,quote=FALSE)
