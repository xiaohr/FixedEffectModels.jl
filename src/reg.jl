
function reg(f::Formula, df::AbstractDataFrame, vcov_method::AbstractVcovMethod = VcovSimple(); weight::Union(Symbol, Nothing) = nothing, subset::Union(AbstractVector{Bool}, Nothing) = nothing, maxiter::Int = 10000, tol::Float64 = 1e-8, save = false)

	# decompose formula into endogeneous form model, reduced form model, absorb model
	rf = deepcopy(f)
	(has_absorb, absorb_formula, absorb_terms, has_iv, iv_formula, iv_terms, endo_formula, endo_terms) = decompose!(rf)
	rt = Terms(rf)
	has_weight = weight != nothing

	# create a dataframe without missing values & negative weights
	vars = allvars(rf)
	absorb_vars = allvars(absorb_formula)
	iv_vars = allvars(iv_formula)
	endo_vars = allvars(endo_formula)
	vcov_vars = allvars(vcov_method)

	# create a dataframe without missing values & negative weights
	all_vars = vcat(vars, vcov_vars, absorb_vars, endo_vars, iv_vars)
	all_vars = unique(convert(Vector{Symbol}, all_vars))
	esample = complete_cases(df[all_vars])
	if has_weight
		esample &= isnaorneg(df[weight])
		all_vars = unique(vcat(all_vars, weight))
	end
	if subset != nothing
		length(subset) == size(df, 1) || error("the number of rows in df is $(size(df, 1)) but the length of subset is $(size(df, 2))")
		esample &= convert(BitArray, subset)
	end
	subdf = df[esample, all_vars]
	(size(subdf, 1) > 0) || error("sample is empty")
	# remove unusued levels
	main_vars = unique(convert(Vector{Symbol}, vcat(vars, endo_vars, iv_vars)))
	for v in main_vars
		# in case subdataframe, don't construct subdf[v] if you dont need to do it
		if typeof(df[v]) <: PooledDataArray
			dropUnusedLevels!(subdf[v])
		end
	end

	# Compute weight
	sqrtw = get_weight(subdf, weight)

	# Compute fes, an array of AbtractFixedEffects
	if has_absorb
		fes = AbstractFixedEffect[FixedEffect(subdf, a, sqrtw) for a in absorb_terms.terms]
		# in case some FixedEffect is aFixedEffectIntercept, remove the intercept
		if any([typeof(f) <: FixedEffectIntercept for f in fes]) 
			rt.intercept = false
		end
	else
		fes = nothing
	end

	# Compute data for std errors
	vcov_method_data = VcovMethodData(vcov_method, subdf)

	# initialize iterations and converged
	iterations = Int[]
	converged = Bool[]

	# Compute X
	mf = simpleModelFrame(subdf, rt, esample)
	coef_names = coefnames(mf)
	Xexo = ModelMatrix(mf).m
	broadcast!(*, Xexo, Xexo, sqrtw)
	demean!(Xexo, iterations, converged, fes; maxiter = maxiter, tol = tol)

	# Compute y
	py = model_response(mf)[:]
	if eltype(py) != Float64
		y = convert(py, Float64)
	else
		y = py
	end
	broadcast!(*, y, y, sqrtw)
	demean!(y, iterations, converged, fes; maxiter = maxiter, tol = tol)

	# Compute Xendo and Z
	if has_iv
		mf = simpleModelFrame(subdf, endo_terms, esample)
		coef_names = vcat(coef_names, coefnames(mf))
		Xendo = ModelMatrix(mf).m
		broadcast!(*, Xendo, Xendo, sqrtw)
		demean!(Xendo, iterations, converged, fes; maxiter = maxiter, tol = tol)


		mf = simpleModelFrame(subdf, iv_terms, esample)
		Z = ModelMatrix(mf).m
		size(Z, 2) >= size(Xendo, 2) || error("Model not identified. There must be at least as many ivs as endogeneneous variables")
		broadcast!(*, Z, Z, sqrtw)
		demean!(Z, iterations, converged, fes; maxiter = maxiter, tol = tol)
	end

	if has_iv
		X = hcat(Xexo, Xendo)
	else
		X = Xexo
	end

	# Compute Xhat
	if has_iv
		newZ = hcat(Xexo, Z)
		crossz = cholfact!(At_mul_B(newZ, newZ))
		Pi = crossz \ At_mul_B(newZ, Xendo)
		Xhat = hcat(Xexo, newZ * Pi)

		# prepare residuals used for first stage F statistic
		## partial out Xendo in place wrt (Xexo, Z)
		Xendo_res = BLAS.gemm!('N', 'N', -1.0, newZ, Pi, 1.0, Xendo)

		## partial out Z in place wrt Xexo
		Pi2 = cholfact!(At_mul_B(Xexo, Xexo)) \ At_mul_B(Xexo, Z)
		Z_res = BLAS.gemm!('N', 'N', -1.0, Xexo, Pi2, 1.0, Z)
	else
		Xhat = Xexo
	end


	# Compute coef and residuals
	crossx = cholfact!(At_mul_B(Xhat, Xhat))
	coef = crossx \ At_mul_B(Xhat, y)
	residuals = y - X * coef

	# Compute degrees of freedom
	df_intercept = 0
	if has_absorb || rt.intercept
		df_intercept = 1
	end
	df_absorb = 0
	if has_absorb 
		## poor man adjustement of df for clustedered errors + fe: only if fe name != cluster name
		for fe in fes
			df_absorb += (typeof(vcov_method) == VcovCluster && in(fe.name, vcov_vars)) ? 0 : sum(fe.scale .!= zero(Float64))
		end
	end
	nobs = size(X, 1)
	df_residual = size(X, 1) - size(X, 2) - df_absorb 

	# Compute ess, tss, r2, r2 adjusted
	(ess, tss) = compute_ss(residuals, y, rt.intercept, sqrtw)

	r2 = 1 - ess / tss 
	r2_a = 1 - ess / tss * (nobs - rt.intercept) / df_residual 

	# Compute standard error
	vcov_data = VcovData{1}(inv(crossx), Xhat, residuals, df_residual)
	matrix_vcov = vcov!(vcov_method_data, vcov_data)

	# Compute Fstat
	coefF = deepcopy(coef)
	matrix_vcovF = matrix_vcov
	if rt.intercept
		coefF = coefF[2:end]
		matrix_vcovF = matrix_vcovF[2:end, 2:end]
	end
	F = diagm(coefF)' * inv(matrix_vcovF) * diagm(coefF)
	F = F[1] 
	if typeof(vcov_method) == VcovCluster 
		nclust = minimum(values(vcov_method_data.size))
		p = ccdf(FDist(size(X, 1) - df_intercept, nclust - 1), F)
	else
		p = ccdf(FDist(size(X, 1) - df_intercept, df_residual - df_intercept), F)
	end

	# Compute augmentdf
	augmentdf = DataFrame()
	if save
		broadcast!(/, residuals, residuals, sqrtw)
		if all(esample)
			augmentdf[:residuals] = residuals
		else
			augmentdf[:residuals] =  DataArray(Float64, length(esample))
			augmentdf[esample, :residuals] = residuals
		end
		if has_absorb
			mf = simpleModelFrame(subdf, rt, esample)
			oldX = ModelMatrix(mf).m
			py = model_response(mf)[:]
			if eltype(py) != Float64
				y = convert(py, Float64)
			else
				y = py
			end
			oldresiduals = y - oldX * coef
			b = oldresiduals - residuals
			fe = getfe(fes, b)
			augmentdf = hcat(augmentdf, DataFrame(fes, fe, esample))
		end
	end


	# iter and convergence
	if has_absorb
		iterations = sum(iterations)
		converged = all(converged)
	end

	# Compute Fstat first stage based on Kleibergen-Paap
	if has_iv
		(F_kp, p_kp) = rank_test!(Xendo_res, Z_res, Pi[(size(Pi, 1) - size(Z_res, 2) + 1):end, :], vcov_method_data, size(X, 2),df_absorb)
	end


	# return
	!has_iv && !has_absorb && return(RegressionResult(coef, matrix_vcov, esample, augmentdf, coef_names, rt.eterms[1], f, nobs, df_residual, r2, r2_a, F, p))
	has_iv && !has_absorb && return(RegressionResultIV(coef, matrix_vcov, esample, augmentdf, coef_names, rt.eterms[1], f, nobs, df_residual, r2, r2_a, F,p, F_kp, p_kp))
	!has_iv && has_absorb && return(RegressionResultFE(coef, matrix_vcov, esample, augmentdf,coef_names, rt.eterms[1], f, nobs, df_residual, r2, r2_a, F, p, iterations, converged))
	has_iv && has_absorb && return(RegressionResultFEIV(coef, matrix_vcov, esample, augmentdf, coef_names, rt.eterms[1], f, nobs, df_residual, r2, r2_a, F,p, F_kp, p_kp, iterations, converged))
end


function compute_ss(residuals::Vector{Float64}, y::Vector{Float64}, hasintercept::Bool, sqrtw::Ones)
	ess = abs2(norm(residuals))
	if hasintercept
		tss = zero(Float64)
		m = mean(y)::Float64
		@inbounds @simd  for i in 1:length(y)
			tss += abs2((y[i] - m))
		end
	else
		tss = abs2(norm(y))
	end
	return (ess, tss)
end
function compute_ss(residuals::Vector{Float64}, y::Vector{Float64}, hasintercept::Bool, sqrtw::Vector{Float64})
	ess = abs2(norm(residuals))
	if hasintercept
		m = (mean(y) / sum(sqrtw) * length(residuals))::Float64
		tss = zero(Float64)
		@inbounds @simd  for i in 1:length(y)
		 tss += abs2(y[i] - sqrtw[i] * m)
		end
	else
		tss = abs2(norm(y))
	end
	return (ess, tss)
end



