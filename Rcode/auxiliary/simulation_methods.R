library(norm)
library(parallel)
library(tidyverse)
library(pbapply)
library(mvtnorm)
library(caret)
library(sn)
library(e1071)
#############################"
# X generators
# These functions are used to load or simulate datasets

X.basic.MVN = function(args){
  n. = args$n
  rho. = args$rho
  p. = args$p
  X = rmvnorm(n., sigma = (1-rho.)*diag(p.) + rho.)
  colnames(X) = 1:ncol(X)
  for(i in 1:ncol(X)){
    colnames(X)[i] = paste('V',i, sep='')
  }
  return(X)
}

# mvtnorm with two groups of variables correlated together
X.two.groups.MVN = function(args){
  n. = args$n
  p. = args$p
  rho. = args$rho

  p2 = ceiling(p./2)
  p1 = p. - p2
  M1 = (1-rho.)*diag(p1) + rho.
  M2 = (1-rho.)*diag(p2) + rho.
  z12 = matrix(0, nrow=p1, ncol=p2)
  z21 = matrix(0, nrow=p2, ncol=p1)
  s = cbind(
    rbind(M1, z21),
    rbind(z12, M2)
  )
  X = rmvnorm(n., sigma=s)
  return(X)
}

#############################
# y generators
# Used to generate/load the response variable

y.regression = function(X, args){
  # Basic noisy linear combination of X
  beta = rep(1, ncol(X))
  y = X %*% beta + rnorm(nrow(X), 0, sqrt(args$sigma_reg))
  return(list(X=X, y=y, beta=beta))
}

if(exists(aux.folder)){
  old = aux.folder
}else{
  old = './'
}
aux.folder = './'
source(paste(aux.folder,'dataloaders.R',sep=''), chdir = T)
aux.folder = old

X.load = function(args){
  # To load a dataset defined in dataloader
  dataset = args$dataset
  n.= args$n
  return(list(n=n., ds=dataset))
}

y.load = function(X, args){
  data_folder = '../../../Data/'
  dat_load = loader(X$ds, max_rows=X$n)
  return(
    list(X=as.matrix(dat_load$X_numeric), y=dat_load$y)
  )
}
###########################

# Loaders for the abalone data
X.abalone = function(args){args$dataset='abalone'; X.load(args)}
y.abalone = y.load

# Loaders for the trauma data
X.trauma = function(args){args$dataset='trauma'; X.load(args)}
y.trauma = function(X, args){
  data_folder = '../../../Data/'
  dat_load = loader(X$ds, max_rows=X$n)
  return(
    list(X=as.matrix(dat_load$X_numeric), y=as.numeric(dat_load$y)-1, X.aux=dat_load$X_category)
  )
}

#########################
# Split

# Split the dataset for cross_validation
train_test_split = function(X,y, train_prop){
  intrain = createDataPartition(y, p=train_prop, list=FALSE)
  return(list(
    X.train = X[intrain,],
    X.test = X[-intrain,],
    y.train = y[intrain],
    y.test = y[-intrain],
    inTrain=intrain
  ))
}

#########################
# Prediction
# Package predictors in a standard way to change them easily in future code

###
# Linear regression
pred.lin.train = function(X.train, y.train, weights=NULL){
  dat = data.frame(y=y.train, X=I(X.train))
  return(
    lm(y~X, data = dat, weights=weights)
  )
}

pred.lin.predict = function(model, X.test){
  return(predict(model,data.frame(X=I(X.test))))
}

reg.lin = list(train=pred.lin.train, predict=pred.lin.predict)

###
# Logistic regression
pred.logit.train = function(X.train, y.train, weights=NULL){
  dat_train = data.frame(y=y.train, X=I(X.train))
  return(
    glm(y ~ .,family=binomial(link='logit'),data=dat_train, weights=weights)
  )
}

pred.logit.predict = function(model, X.test){
  return(predict(model,data.frame(X=I(X.test)), type='response'))
}

reg.logit = list(train=pred.logit.train, predict=pred.logit.predict)

###
# RF prediction
pred.rf.train = function(X.train, y.train){
  fitControl = trainControl(method = "none", classProbs = F)
  fittedM = train(X.train, y.train,
                  method='rf',
                  trControl=fitControl)
  return(fittedM)
}

pred.rf.predict = function(model, X.test){
  return(
    predict(model, X.test)
  )
}
reg.rf = list(train=pred.rf.train, predict=pred.rf.predict)

###
# SVM prediction
pred.svm.train = function(X.train, y.train){
  dat_train = data.frame(y=y.train, X=I(X.train))
  return(
    svm(y ~ .,data=dat_train)
  )
}

pred.svm.predict = function(model, X.test){
  return(predict(model,data.frame(X=I(X.test)), probability=T))
}

reg.svm = list(train=pred.svm.train, predict=pred.svm.predict)

################
# Imputation
imp.mean.train = function(X){
  # Imputation by the mean
  return(colMeans(X, na.rm = T))
}
imp.mean.estim = function(mu, X){
  p = ncol(X)
  for(i in 1:p){
    X[is.na(X[,i]),i] = mu[i]
  }
  return(X)
}

################################
# Evaluation
# Functions used to run some given code multiple times in parallel,
# Usually in order to see the variation of the error

evaluate.S.run.general = function(S, args, evaluator, do.parallel=T, no_cores=4, seed=NULL){
  # Runs evaluator S times and returns a dataframe of the results
  # Evaluator should return a named list of scalar values
  # Variables contained in args are passed on to the evaluator
  
  #/!\ For now the seeding system is quite intricate:
  # We need two different kinds of seed
  # - rngseed seeds a separate RNG for the norm package functions
  # - the standard RNG is seeded with set.seed or clusertSetRNGStream
  # The standard RNG cannot be seeded with set.seed if we then use a parallel function (eg parlapply).
  # But for some reason, if we just seed using clusterSetRNGStream, then if we repeat the same code S
  # time we get the same results every time (even though this function is supposed to set a *different* seed
  # for each core). 
  # This is why we use the 'seed.run' global variable for a quick fix to this:
  # the code that calls evaluate.S.run will first declare a global seed.run variable, and also
  # ensure that the evaluator function uses seed.run to set its own seed.
  # This is why we increment seed.run at each run: it will be the actual seed of the run,
  # but this must be implemented inside the evaluator
  # There is probably a better fix, but this works: results are reproducible and the 
  # S runs are independent
  
  f= function(i){
    if(!is.null(seed)){
      rngseed(seed+i)
    }
    if(exists('seed.run')){
      args$seed.run = seed.run + i
    }
    evaluator(args)
  }
  if(do.parallel){
    cl <- makeCluster(no_cores, type='FORK')
    if(!is.null(seed)){
      clusterSetRNGStream(cl, seed)
    }
    z = pblapply(cl=cl, X=1:S, FUN=f)
    stopCluster(cl)
  }
  else{
    z = pblapply(X=1:S, FUN=f)
  }

  # Manipulations to get from the results to a useful dataframe 
  zz <- lapply(z, `[`, names(z[[1]]))
  res = apply(do.call(rbind, zz), 2, as.list)

  return(lapply(res, unlist))
}

expand_args = function(argsList){
  # Gets a list of vectors and creates a list of list where each list is one
  # Possible combination of the values in the vectors
  # Example:
  # expand_args(list(arg_a=c(1,2), arg_b=c(3,4)))
  # => list(1=list(a=1,b=3), 2=list(a=1,b=4), 3=list(a=2,b=3), 4=list(a=2,b=4))
  
  # Used for parameter exploration
  args.df = expand.grid(argsList)
  return(
    split(args.df, seq(nrow(args.df)))
  )
}

evaluate.S.run.multiArg = function(S, argsList, evaluator, do.parallel=T, stackAll=F, no_cores=4){
  # For every possible combination in argsList, performs S runs of the evaluator
  # If stackAll==T, then all of the results are returned without aggregation,
  # otherwise for each set of parameter the mean is returned
  # The dataframe of results contains as columns the values returned by the evaluator,
  # and the arguments
  args.df = expand.grid(argsList)
  argsList = expand_args(argsList)

  if(!stackAll){
    f= function(args){
      rngseed(seed)
      evaluate.S.run.general(S, args, evaluator, do.parallel=F) %>% lapply(mean)
    }
  }else{
    f= function(args){
      rngseed(seed)
      evaluate.S.run.general(S, args, evaluator, do.parallel=F)
    }
  }
  if(do.parallel){
    cl <- makeCluster(no_cores, type='FORK')
    clusterSetRNGStream(cl, seed)
    z = pblapply(cl=cl, X=argsList, FUN=f)
    stopCluster(cl)
  }
  else{
    z = pblapply(X=argsList, FUN=f)
  }

  zz <- lapply(z, `[`, names(z[[1]]))
  res = apply(do.call(rbind, zz), 2, as.list)

  return(
    cbind(lapply(res, unlist) %>% as.data.frame(), args.df)
  )
}
