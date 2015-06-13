survCreateJagsData <- function(det.part, data) {
  # Creates the parameters to define the prior of the log-logistic binomial model
  # INPUTS
  # det.part: model name
  # data: object of class survData
  # OUTPUT
  # jags.data : list of data required for the jags.model function

  # Parameter calculation of concentration min and max
  concmin <- min(sort(unique(data$conc))[-1])
  concmax <- max(data$conc)

  # Create prior parameters for the log logistic model

  # Params to define e
  meanlog10e <- (log10(concmin) + log10(concmax)) / 2
  sdlog10e <- (log10(concmax) - log10(concmin)) / 4
  taulog10e <- 1 / sdlog10e^2

  # Params to define b
  log10bmin <- -2
  log10bmax <- 2

  # list of data use by jags
  jags.data <- list(meanlog10e = meanlog10e,
                    Ninit = data$Ninit,
                    Nsurv = data$Nsurv,
                    taulog10e = taulog10e,
                    log10bmin = log10bmin,
                    log10bmax = log10bmax,
                    n = length(data$conc),
                    xconc = data$conc)

  # list of data use by jags
  if (det.part == "loglogisticbinom_3") {
    jags.data <- c(jags.data,
                   dmin = 0,
                   dmax = 1)
  }
  return(jags.data)
}

#' @import rjags
survLoadModel <- function(model.program,
                          data,
                          n.chains,
                          Nadapt,
                          quiet = quiet) {
  # create the JAGS model object
  # INPUTS:
  # - model.program: character string containing a jags model description
  # - data: list of data created by survCreateJagsData
  # - nchains: Number of chains desired
  # - Nadapt: length of the adaptation phase
  # - quiet: silent option
  # OUTPUT:
  # - JAGS model

  # load model text in a temporary file
  model.file <- tempfile() # temporary file address
  fileC <- file(model.file) # open connection
  writeLines(model.program, fileC) # write text in temporary file
  close(fileC) # close connection to temporary file

  # creation of the jags model
  model <- jags.model(file = model.file, data = data, n.chains = n.chains,
                      n.adapt = Nadapt, quiet = quiet)
  unlink(model.file)
  return(model)
}

survPARAMS <- function(mcmc, det.part) {
  # create the table of posterior estimated parameters
  # for the survival analyses
  # INPUT:
  # - mcmc:  list of estimated parameters for the model with each item representing
  # a chain
  # OUTPUT:
  # - data frame with 3 columns (values, CIinf, CIsup) and 3-4rows (the estimated
  # parameters)

  # Retrieving parameters of the model
  res.M <- summary(mcmc)

  if (det.part ==  "loglogisticbinom_3") {
    d <- res.M$quantiles["d", "50%"]
    dinf <- res.M$quantiles["d", "2.5%"]
    dsup <- res.M$quantiles["d", "97.5%"]
  }
  # for loglogisticbinom_2 and 3
  b <- 10^res.M$quantiles["log10b", "50%"]
  e <- 10^res.M$quantiles["log10e", "50%"]
  binf <- 10^res.M$quantiles["log10b", "2.5%"]
  einf <- 10^res.M$quantiles["log10e", "2.5%"]
  bsup <- 10^res.M$quantiles["log10b", "97.5%"]
  esup <- 10^res.M$quantiles["log10e", "97.5%"]

  # Definition of the parameter storage and storage data
  # If Poisson Model

  if (det.part == "loglogisticbinom_3") {
    # if mortality in control
    rownames <- c("b", "d", "e")
    params <- c(b, d, e)
    CIinf <- c(binf, dinf, einf)
    CIsup <- c(bsup, dsup, esup)
  } else {
    # if no mortality in control
    # Definition of the parameter storage and storage data
    rownames <- c("b", "e")
    params <- c(b, e)
    CIinf <- c(binf, einf)
    CIsup <- c(bsup, esup)
  }

  res <- data.frame(median = params, Q2.5 = CIinf, Q97.5 = CIsup,
                    row.names = rownames)

  return(res)
}

llbinom3.model.text <- "\nmodel # Loglogistic binomial model with 3 parameters\n\t\t{\t\nfor (i in 1:n)\n{\np[i] <- d/ (1 + (xconc[i]/e)^b)\nNsurv[i]~ dbin(p[i], Ninit[i])\n}\n\n# specification of priors (may be changed if needed)\nd ~ dunif(dmin, dmax)\nlog10b ~ dunif(log10bmin, log10bmax)\nlog10e ~ dnorm(meanlog10e, taulog10e)\n\nb <- pow(10, log10b)\ne <- pow(10, log10e)\n}\n"

llbinom2.model.text <- "\nmodel # Loglogistic binomial model with 2 parameters\n\t\t{\t\nfor (i in 1:n)\n{\np[i] <- 1/ (1 + (xconc[i]/e)^b)\nNsurv[i]~ dbin(p[i], Ninit[i])\n}\n\n# specification of priors (may be changed if needed)\nlog10b ~ dunif(log10bmin, log10bmax)\nlog10e ~ dnorm(meanlog10e, taulog10e)\n\nb <- pow(10, log10b)\ne <- pow(10, log10e)\n}\n"


#' Fit a Bayesian exposure-response model for endpoint survival analysis
#'
#' The \code{survFitTT} function estimates the parameters of an exposure-response
#' model for endpoint survival analysis using Bayesian inference. In this model,
#' the survival rate of individuals after some time (called target time) is modeled
#' as a function of the pollutant's concentration, called deterministic part. The
#' actual number of
#' surviving individuals is then modeled as a stochastic function of the survival
#' rate, called the stochastic part. Details of the model are presented in the
#' vignette accompanying the package.
#'
#' The function returns
#' parameter estimates of the exposure-response model and estimates of the so-called
#' LCx, that is the concentration of pollutant required to obtain an 1 - x survival
#' rate.
#'
#'
#'
#' Two deterministic parts are proposed: the log-logistic binomial function with two or three parameters in
#' order to take into account the mortality in the control.
#' \describe{
#' \item{"loglogisticbinom_2" deterministic part:}{ this model must
#' be chosen when there is no mortality in the control at the target-time.  The
#' survival rate at concentration \eqn{C_{i}}{C_{i}} was described by:
#' \deqn{f(C_{i}) = \frac{1}{ 1 + (\frac{C_{i}}{e})^b}}{f(C_{i}) = 1 / (1 +
#' (C_{i} / e)^b)} where \eqn{e} is the 50 \% lethal concentration
#' (\eqn{LC_{50}}{LC50}) and \eqn{b} is a slope parameter. For parameter
#' \eqn{e}, the function assumed that the experimental design was defined from
#' a prior knowledge on the \eqn{LC_{50}}{LC50}, with a probability of 95 \%
#' for the expected value to lie between the smallest and the highest tested
#' concentrations. Hence, a log-normal distribution for \eqn{e} was calibrated
#' from that prior knowledge. The number of survivor at concentration \eqn{i}
#' and replicate \eqn{j} was described by a Binomial distribution:
#' \deqn{Nsurv_{ij} \sim Binomial(f(C_{i}), Ninit_{ij})}{Nsurv_{ij} ~
#' Binomial(f(C_{i}), Ninit_{ij})} where \eqn{Ninit_{ij}}{Ninit_{ij}} is the
#' initial number of offspring at the beginning of bioassay. The slope
#' parameter \eqn{b} was characterized by a prior log-uniform distribution
#' between -2 and 2 in decimal logarithm.} \item{"loglogisticbinom_3"
#' deterministic part:}{ this model must be chosen when there is mortality in
#' the control at the target-time.  The survival rate at concentration
#' \eqn{C_{i}}{C_{i}} was described by: \deqn{f(C_{i}) = \frac{d}{ 1 +
#' (\frac{C_{i}}{e})^b}}{f(C_{i}) = d / (1 + (C_{i} / e)^b)} where \eqn{d}
#' stands for survival rate in the control when this one is not equal to one.
#' The parameter \eqn{d} was characterized by a prior uniform distribution
#' between 0 and 1.}
#' }
#'
#' Credible limits: For 100 values of concentrations regularly spread within
#' the range of tested concentrations the joint posterior distribution of
#' parameters is used to simulate 5000 values of \eqn{f_{ij}}, the number of
#' offspring per individual-day for various replicates. For each concentration,
#' 2.5, 50 and 97.5 percentiles of simulated values are calculated, from which
#' there is a point estimate and a 95 \% credible interval (Delignette-Muller
#' et al., 2014).
#'
#' DIC: The Deviance Information Criterium (DIC) as defined by Spiegelhalter et
#' al. (2002) is provided by the \code{dic.samples} function. The DIC is a
#' goodness-of-fit criterion penalized by the complexity of the model
#' (Delignette-Muller et al., 2014).
#'
#' Raftery and Lewis's diagnostic: The \code{raftery.diag} is a run length
#' control diagnostic based on a criterion that calculates the appropriate
#' number of iterations required to accurately estimate the parameter
#' quantiles. The Raftery and Lewis's diagnostic value used in the
#' \code{surFitTT} function is the \code{resmatrix} object. See the
#' \code{\link[coda]{raftery.diag}} help for more details.
#'
#' @aliases survFitTT
#'
#' @param data An object of class \code{survData}.
#' @param det.part Deterministic part of the model. Valid values are
#' "loglogisticbinom_2" and "loglogisticbinom_3"
#' @param target.time The chosen endpoint to evaluate the effect of a given
#' concentration of pollutant. By default the last time point available for
#' all concentrations.
#' @param lcx Values of \eqn{x} to calculate desired \eqn{LC_{x}}{LCx}.
#' @param n.chains Number of MCMC chains. The minimum required number of chains
#' is 2.
#' @param quiet If \code{TRUE}, make silent all prints and progress bars of
#' JAGS compilation.
# @param x An object of class \code{survFitTT}.
# @param xlab A label for the \eqn{X}-axis, by default \code{Concentrations}.
# @param ylab A label for the \eqn{Y}-axis, by default \code{Response}.
# @param main A main title for the plot.
# @param fitcol A single color to plot the fitted curve, by default
# \code{red}.
# @param fitlty A single line type to plot the fitted curve, by default
# \code{1}.
# @param fitlwd A single numeric which controls the width of the fitted curve,
# by default \code{1}.
# @param ci If \code{TRUE}, the 95 \% credible limits of the model are
# plotted.
# @param cicol A single color to plot the 95 \% credible limits, by default
# \code{red}.
# @param cilty A single line type to plot 95 \% credible limits, by default
# \code{1}.
# @param cilwd A single numeric which controls the width of the 95 \% credible
# limits, by default \code{2}.
# @param addlegend If \code{TRUE}, a default legend is added to the plot.
# @param log.scale If \code{TRUE}, a log-scale is used on the \eqn{X}-axis.
# @param style Graphical method: \code{generic} or \code{ggplot}.
# @param ppc If \code{TRUE}, plot a representation of predictions as 95 \%
# credible intervals, against observed values.
# @param pool.replicate If \code{TRUE}, the datapoints of each replicate are
# pooled together for a same concentration. The circles matches to the mean of
# datapoints for one concentration.
# @param \dots Further arguments to be passed to generic methods.
#'
#' @return The function returns an object of class \code{survFitTT}. A list
#' of 13 objects:
#' \item{DIC}{DIC value of the selected model.}
#' \item{estim.LCx}{A table of the estimated 5, 10, 20 and 50 \% lethal
#' concentrations and their 95 \% credible intervals.}
#' \item{estim.par}{A table of the estimated parameters as medians and 95 \%
#' credible intervals.}
#' \item{det.part}{The name of the deterministic part of the used model.}
#' \item{mcmc}{An object of class \code{mcmc.list} with the posterior
#' distributions.}
#' \item{model}{A JAGS model object.}
#' \item{parameters}{A list of the parameters names used in the model.}
#' \item{n.chains}{An integer value corresponding to the number of chains used
#' for the MCMC computation.}
#' \item{n.iter}{A list of two numerical value corresponding to the beginning
#' and the end of monitored iterations.}
#' \item{n.thin}{A numerical value corresponding to the thinning interval.}
#' \item{jags.data}{A list of data used by the internal \code{\link[rjags]{jags.model}}
#' function. This object is intended for the case when the user wishes to use
#' the \code{\link[rjags]{rjags}} package instead of the automatied estimation
#' function.}
#' \item{transformed.data}{The \code{survData} object.
#' See \code{\link{survData}} for details.}
#' \item{dataTT}{The subset of transformed.data at target time.}
#'
#' FIXME
#'
#' Generic functions: \describe{
#' \item{\code{summary}}{provides the following information: the type of model
#' used, median and 2.5 \% and 97.5 \% quantiles of priors on estimated parameter
#' distributions, median and 2.5 \% and 97.5 \% quantiles of posteriors on
#' estimated parameter distributions and median and 2.5 \% and 97.5 \% quantiles
#' of \eqn{LC_{x}}{LCx} estimates (x = 5, 10, 20, 50 by default).}
#' \item{\code{print}}{shows information about the estimation method: the full
#' JAGS model, the number of chains, the total number of iterations, the number
#' of iterations in the burn-in period, the thin value and the DIC.}
#' \item{\code{plot}}{shows the fitted exposure-response curve superimposed to
#' experimental data at target time. The response is here expressed as the survival
#' rate.
#' When \code{ppc = TRUE}, the posterior predictive check representation is drawing
#' in a new graphical window. Two types of output are available: \code{generic}
#' or \code{ggplot}.
#' }}
#'
#' @author Marie Laure Delignette-Muller
#' <marielaure.delignettemuller@@vetagro-sup.fr>, Philippe Ruiz
#' <philippe.ruiz@@univ-lyon1.fr>
#'
#' @seealso \code{\link[rjags]{rjags}}, \code{\link[rjags]{coda.samples}},
#' \code{\link[rjags]{dic.samples}}, \code{\link[coda]{summary.mcmc}},
#' \code{\link[dclone]{parJagsModel}}, \code{\link[dclone]{parCodaSamples}},
#' \code{\link{survData}}, \code{\link[coda]{raftery.diag}} and
#' \code{\link[ggplot2]{ggplot}}
#'
#' @references Plummer, M. (2013) JAGS Version 3.4.0 user manual.
#' \url{http://sourceforge.net/projects/mcmc-jags/files/Manuals/3.x/jags_user_manual.pdf/download}
#'
#' Spiegelhalter, D., N. Best, B. Carlin, and A. van der Linde (2002) Bayesian
#' measures of model complexity and fit (with discussion).  \emph{Journal of
#' the Royal Statistical Society}, Series B 64, 583-639.
#'
#' @keywords estimation
#
#' @examples
#'
#' # From repro-survival data
#' # With mortality in the control dataset
#' # (1) Load the data
#' data(cadmium1)
#'
#' # (2) Create an object of class "survData"
#' dat <- survData(cadmium1)
#'
#' \dontrun{
#' # (3) Run the survFitTT function with the three parameters log-logistic
#' # binomial model
#' out <- survFitTT(dat, det.part = "loglogisticbinom_3",
#' lcx = c(5, 10, 15, 20, 30, 50, 80), quiet = TRUE)
#'
#' # (3') Run the fit (parallel version)
#' out <- survParfitTT(dat, det.part = "loglogisticbinom_3",
#' lcx = c(5, 10, 15, 20, 30, 50, 80), quiet = TRUE)
#'
#' # (4) Summary
#' # out
#' # summary(out)
#'
#' # (5) Plot the fitted curve
#' plot(out, log.scale = TRUE, ci = TRUE)
#'
#' # (6) Plot the fitted curve with ggplot style
#' plot(out, xlab = expression("Concentration in" ~ mu~g.L^{-1}),
#' fitcol = "blue", ci = TRUE, cicol = "blue",  style = "ggplot")
#'
#' # (7) Add a specific legend with generic type
#' plot(out, addlegend = FALSE)
#' legend("left", legend = c("Without mortality", "With mortality"),
#' pch = c(19,1))
#'
#' # (8) Plot posterior predictive check
#' plot(out, ppc = TRUE)
#' }
#'
#' # Without mortality in the control dataset
#' # (1) Load the data
#' data(cadmium2)
#'
#' # (2) Create an object of class "survData"
#' dat2 <- survData(cadmium2)
#'
#' \dontrun{
#' # (3) Run the fit
#' out <- survFitTT(dat2, det.part = "loglogisticbinom_2",
#' lcx = c(5, 10, 15, 20, 30, 50, 80), quiet = TRUE)
#'
#' # (3') Run the fit (parallel version)
#' out <- survParfitTT(dat2, det.part = "loglogisticbinom_2",
#' n.chains = 3)
#'
#' # (4) Summary
#' # out
#' # summary(out)
#'
#' # (5) Plot the fitted curve
#' plot(out, log.scale = TRUE, ci = TRUE,
#' main = "log-logistic binomial 2 parameters model")
#'
#' # (6) Plot the fitted curve with ggplot style
#' plot(out, xlab = expression("Concentration in" ~ mu~g.L^{-1}),
#' fitcol = "blue", ci = TRUE, cicol = "blue",  style = "ggplot",
#' main = "log-logistic binomial 2 parameters model")
#'
#' # (7) Add a specific legend with generic style
#' plot(out, addlegend = FALSE)
#' legend("left", legend = c("Without mortality", "With mortality"),
#' pch = c(19,1))
#'
#' # (8) Plot posterior predictive check
#' plot(out, ppc = TRUE)
#'
#' # (9) Don't pool the replicate
#' plot(out, pool.replicate = FALSE)
#' }
#'
#' @export
#'
#' @import rjags
#' @importFrom dplyr filter
#'
survFitTT <- function(data,
                      det.part = "loglogisticbinom_2",
                      target.time = NULL,
                      lcx,
                      n.chains = 3,
                      quiet = FALSE) {
  # test class object
  if(! is(data, "survData"))
    stop("survFitTT: object of class survData expected")

  # test determinist part
  if (! (det.part == "loglogisticbinom_2" || det.part == "loglogisticbinom_3"))
    stop("Invalid value for argument [det.part]")

  # select model text
  if (det.part == "loglogisticbinom_2") {
    model.text <- llbinom2.model.text
  }
  if (det.part == "loglogisticbinom_3") {
    model.text <- llbinom3.model.text
  }

  # parameters
  parameters <- if (det.part == "loglogisticbinom_2") {
    c("log10b", "log10e")
  } else {
    if (det.part == "loglogisticbinom_3") {
      c("log10b", "d", "log10e")}
  }

  # select Data at target.time
  dataTT <- selectDataTT(data, target.time)

  # create priors parameters
  jags.data <- survCreateJagsData(det.part, dataTT)

  # Test mortality in the control
  # FIXME: I don't get why we leave a choice to the user here:
  # the choice of the model is dictated by mortality in the control!
  control <- filter(dataTT, conc == 0)
  if (
      det.part == "loglogisticbinom_2"
    &&
      any(control$Nsurv < control$Ninit)
  )
    stop("Beware! There is mortality in the control. A model with three parameters must be chosen.")

  if (
      det.part == "loglogisticbinom_3"
    &&
      ! any(control$Nsurv < control$Ninit)
    )
    stop("Beware! There is no mortality in the control. A model with two parameters must be chosen.")

  # Model computing

  # Define model
  model <- survLoadModel(model.program = model.text,
                         data = jags.data, n.chains,
                         Nadapt = 3000, quiet)

  # Determine sampling parameters
  sampling.parameters <- modelSamplingParameters(model,
                                                 parameters, n.chains, quiet)

  if (sampling.parameters$niter > 100000)
    stop("The model needs too many iterations to provide reliable parameter estimates !")

  # calcul DIC
  modelDIC <- calcDIC(model, sampling.parameters, quiet)

  # Sampling
  prog.b <- ifelse(quiet == TRUE, "none", "text")

  mcmc <- coda.samples(model, parameters,
                       n.iter = sampling.parameters$niter,
                       thin = sampling.parameters$thin,
                       progress.bar = prog.b)

  # summarize estime.par et CIs
  # calculate from the estimated parameters
  estim.par <- survPARAMS(mcmc, det.part)

  # LCx calculation  estimated LCx and their CIs 95%
  # vector of LCX
  if (missing(lcx)) {
    lcx <- c(5, 10, 20, 50)
  }
  estim.LCx <- estimXCX(mcmc, lcx, "LC")

  # check if estimated LC50 lies in the tested concentration range
  if (50 %in% lcx) {
    LC50 <- log10(estim.LCx["LC50", "median"])
    if (!(min(log10(data$conc)) < LC50 & LC50 < max(log10(data$conc))))
      warning("The LC50 estimation lies outsides the range of tested concentration and may be unreliable !")
  }

  # output
  OUT <- list(DIC = modelDIC,
              estim.LCx = estim.LCx,
              estim.par = estim.par,
              det.part = det.part,
              mcmc = mcmc,
              model = model,
              parameters = parameters,
              n.chains = summary(mcmc)$nchain,
              n.iter = list(start = summary(mcmc)$start,
                            end = summary(mcmc)$end),
              n.thin = summary(mcmc)$thin,
              jags.data = jags.data,
              transformed.data = data,
              dataTT = dataTT)

  class(OUT) <- "survFitTT"
  return(OUT)
}