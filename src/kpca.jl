# Kernel Principal Component Analysis

"""Center a kernel matrix"""
immutable KernelCenter{T<:AbstractFloat}
    means::AbstractVector{T}
    total::T
end

"""Fit `KernelCenter` object"""
function fit{T<:AbstractFloat}(::Type{KernelCenter}, K::AbstractMatrix{T})
    n = size(K, 1)
    means = vec(mean(K, 2))
    KernelCenter(means, sum(means) / n)
end

"""Center kernel matrix."""
function transform!{T<:AbstractFloat}(C::KernelCenter{T}, K::AbstractMatrix{T})
    r, c = size(K)
    tot = C.total
    means = mean(K, 1)
    @simd for i in 1:r
        for j in 1:c
            @inbounds K[i, j] -= C.means[i] + means[j] - tot
        end
    end
    return K
end

"""Kernel PCA type"""
immutable KernelPCA{T<:AbstractFloat}
    X::AbstractMatrix{T}  # fitted data
    ker::Function         # kernel function
    center::KernelCenter  # kernel center
    λ::DenseVector{T}     # eigenvalues  in feature space
    α::DenseMatrix{T}     # eigenvectors in feature space
    inv::DenseMatrix{T}   # inverse transform coefficients
end

## properties

indim(M::KernelPCA) = size(M.X, 1)
outdim(M::KernelPCA) = length(M.λ)

projection(M::KernelPCA) = M.α ./ sqrt.(M.λ')
principalvars(M::KernelPCA) = M.λ

## use

"""Calculate transformation to kernel space"""
function transform{T<:AbstractFloat}(M::KernelPCA{T}, x::AbstractVecOrMat{T})
    k = pairwise(M.ker, M.X, x)
    transform!(M.center, k)
    return projection(M)'*k
end

function transform{T<:AbstractFloat}(M::KernelPCA{T})
    return projection(M)'*M.X
end

"""Calculate inverse transformation to original space"""
function reconstruct{T<:AbstractFloat}(M::KernelPCA{T}, y::AbstractVecOrMat{T})
    if size(M.inv, 1) == 0
        throw(ArgumentError("Inverse transformation coefficients are not available, set `inverse` parameter when fitting data"))
    end
    Pᵗ = M.α' .* sqrt.(M.λ)
    k = pairwise(M.ker, Pᵗ, y)
    return M.inv*k
end

## show

function Base.show(io::IO, M::KernelPCA)
    print(io, "Kernel PCA(indim = $(indim(M)), outdim = $(outdim(M)))")
end

## core algorithms

function pairwise!{T<:AbstractFloat}(K::AbstractVecOrMat{T}, kernel::Function,
                                     X::AbstractVecOrMat{T}, Y::AbstractVecOrMat{T})
    n = size(X, 2)
    m = size(Y, 2)
    for j = 1:m
        aj = view(Y, :, j)
        for i in j:n
            @inbounds K[i, j] = kernel(view(X, :, i), aj)[]
        end
        j <= n && for i in 1:(j - 1)
            @inbounds K[i, j] = K[j, i]   # leveraging the symmetry
        end
    end
    K
end

pairwise!{T<:AbstractFloat}(K::AbstractVecOrMat{T}, kernel::Function, X::AbstractVecOrMat{T}) =
    pairwise!(K, kernel, X, X)

function pairwise{T<:AbstractFloat}(kernel::Function, X::AbstractVecOrMat{T}, Y::AbstractVecOrMat{T})
    n = size(X, 2)
    m = size(Y, 2)
    K = similar(X, n, m)
    pairwise!(K, kernel, X, Y)
end

pairwise{T<:AbstractFloat}(kernel::Function, X::AbstractVecOrMat{T}) =
    pairwise(kernel, X, X)

## interface functions

function fit{T<:AbstractFloat}(::Type{KernelPCA}, X::AbstractMatrix{T};
                               kernel = (x,y)->x'y,
                               maxoutdim::Int = min(size(X)...),
                               remove_zero_eig::Bool = false, atol::Real = 1e-10,
                               solver::Symbol = :eig,
                               inverse::Bool = false,  β::Real = 1.0,
                               tol::Real = 0.0, maxiter::Real = 300)
    d, n = size(X)
    Kfunc = (x,y)->error("Kernel is precomputed.")

    maxoutdim = min(min(d, n), maxoutdim)

    K = if isa(kernel, Function)
        pairwise(kernel, X)
    elseif kernel === nothing
        @assert issymmetric(X) "Precomputed kernel matrix must be symmetric."
        inverse = false
        X
    else
        throw(ArgumentError("Incorrect kernel type. Use function or symmetric matrix."))
    end

    # set kernel function if available
    if isa(kernel, Function)
        Kfunc = kernel
    end

    # center kernel
    center = fit(KernelCenter, K)
    transform!(center, K)

    # perform eigenvalue decomposition
    evl, evc = if solver == :eigs || issparse(K)
        evl, evc = eigs(K, nev=maxoutdim, which=:LR, v0=2.0*rand(n)-1.0, tol=tol, maxiter=maxiter)
        real.(evl), real.(evc)
    else
        Eg = eigfact(Hermitian(K))
        Eg[:values], Eg[:vectors]
    end

    # sort eigenvalues in descending order
    ord = sortperm(evl; rev=true)[1:maxoutdim]

    # remove zero eigenvalues
    λ, α = if remove_zero_eig
        ez = map(!, isapprox.(evl[ord], zero(T), atol=atol))
        evl[ord[ez]], evc[:, ord[ez]]
    else
        evl[ord], evc[:, ord]
    end

    # calculate inverse transform coefficients
    Q = zeros(T, 0, 0)
    if inverse
        Pᵗ = α' .* sqrt.(λ)
        KT = pairwise(Kfunc, Pᵗ)
        Q = (KT + diagm(fill(β, size(KT,1)))) \ X'
    end

    KernelPCA(X, Kfunc, center, λ, α, Q')
end