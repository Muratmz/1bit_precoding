function precoder_sim(varargin)
% =========================================================================
% Simulator for "Quantized Precoding for Massive MU-MIMO" (v1.2)
% -------------------------------------------------------------------------
% Revision history:
%   - apr-06-2018  v1.2   sj: simplified/commented code for GitHub
%   - oct-12-2017  v1.1   cs: 1-bit branch-and-bound added
%   - sep-27-2017  v1.0   sj: minor bug fixes
%   - jun-26-2017  v0.1   sj: simplified/commented code for GitHub
% -------------------------------------------------------------------------
% (c) 2018 Christoph Studer and Sven Jacobsson
% e-mail: studer@cornell.edu and sven.jacobsson@ericsson.com
% -------------------------------------------------------------------------
% If you this simulator or parts of it, then you must cite our paper:
%   -- S. Jacobsson, G. Durisi, M. Coldrey, T. Goldstein, and C. Studer,
%   "Quantized precoding for massive MU-MIMO", IEEE Trans. Commun.,
%   vol. 65, no. 11, pp. 4670--4684, Nov. 2017.
%=========================================================================

    % -- set up default/custom parameters

    if isempty(varargin)
       
        disp('using default simulation settings and parameters...');

        % set default simulation parameters
        par.runId = 0; % simulation ID (used to reproduce results)
        par.plot = true; % plot results (true/false)
        par.save = false; % save results (true/false)
        par.L = 2; % number of DAC levels (2 <= L <= 32)
        par.U = 16; % number of UEs
        par.B = 128; % number of BS antennas
        par.trials = 1e3; % number of Monte-Carlo trials (transmissions)
        par.relerr = 0; % relative channel estimate error
        par.SNRdB_list = -10:3:15; % list of SNR [dB] values to be simulated
        par.mod = 'QPSK'; % modulation type: 'BPSK','QPSK','16QAM','64QAM'
        par.precoder = {'MRT_inf','ZF_inf','MRT','ZF','SQUID'}; % select precoding scheme(s) to be evaluated

    else

        disp('use custom simulation settings and parameters...')
        par = varargin{1}; % load custom simulation parameters

    end

    % -- initialization

    % set unique filename
    par.simName = ['BER_',num2str(par.U),'x',num2str(par.B),'_',num2str(par.mod),...
        '_',num2str(par.runId),'_',datestr(clock,0)];

    % check for SDR precoding
    if find(ismember(par.precoder,'SDR'))
        par.precoder = [par.precoder(1:(find(ismember(par.precoder,'SDR'))-1)), ...
            'SDR1', 'SDRr', par.precoder((find(ismember(par.precoder,'SDR'))+1):end)];
    end

    % add paths
    addpath('precoders');
    addpath('tools');

    % use runId random seed (enables reproducibility)
    rng(par.runId);

    % set up Gray-mapped constellation alphabet
    switch (par.mod)
        case 'BPSK'
            par.symbols = [ -1 1 ];
        case 'QPSK'
            par.symbols = [ -1-1i,-1+1i,+1-1i,+1+1i ];
        case '16QAM'
            par.symbols = [...
                -3-3i,-3-1i,-3+3i,-3+1i, ...
                -1-3i,-1-1i,-1+3i,-1+1i, ...
                +3-3i,+3-1i,+3+3i,+3+1i, ...
                +1-3i,+1-1i,+1+3i,+1+1i ];
        case '64QAM'
            par.symbols = [...
                -7-7i,-7-5i,-7-1i,-7-3i,-7+7i,-7+5i,-7+1i,-7+3i, ...
                -5-7i,-5-5i,-5-1i,-5-3i,-5+7i,-5+5i,-5+1i,-5+3i, ...
                -1-7i,-1-5i,-1-1i,-1-3i,-1+7i,-1+5i,-1+1i,-1+3i, ...
                -3-7i,-3-5i,-3-1i,-3-3i,-3+7i,-3+5i,-3+1i,-3+3i, ...
                +7-7i,+7-5i,+7-1i,+7-3i,+7+7i,+7+5i,+7+1i,+7+3i, ...
                +5-7i,+5-5i,+5-1i,+5-3i,+5+7i,+5+5i,+5+1i,+5+3i, ...
                +1-7i,+1-5i,+1-1i,+1-3i,+1+7i,+1+5i,+1+1i,+1+3i, ...
                +3-7i,+3-5i,+3-1i,+3-3i,+3+7i,+3+5i,+3+1i,+3+3i ];
    end

    % normalize symbol energy
    par.symbols2 = par.symbols/sqrt(sum(abs(par.symbols).^2)/length(par.symbols));

    % precompute bit labels
    par.card = length(par.symbols); % cardinality
    par.bps = log2(par.card); % number of bits per symbol
    par.bits = de2bi(0:par.card-1,par.bps,'left-msb'); % symbols-to-bits

    % initialize result arrays
    res.VER = zeros(length(par.precoder),length(par.SNRdB_list));
    res.SER = zeros(length(par.precoder),length(par.SNRdB_list));
    res.BER  = zeros(length(par.precoder),length(par.SNRdB_list));
    
    % Tx and Rx power (average and max)
    res.TxAvgPower = zeros(length(par.precoder),length(par.SNRdB_list));
    res.RxAvgPower = zeros(length(par.precoder),length(par.SNRdB_list));
    res.TxMaxPower = zeros(length(par.precoder),length(par.SNRdB_list));
    res.RxMaxPower = zeros(length(par.precoder),length(par.SNRdB_list));

    % save results for later viewing
    if par.trials <= 1e3
        shat_list = nan(par.U,length(par.precoder),length(par.SNRdB_list),par.trials);
    end

    % step size that minimizes MSE for standard Gaussian random variables
    lsb_list = [...
        1.59622540846949,...
        1.22434478159386,...
        0.996032010670224,...
        0.842494164721574,...
        0.733821273757919,...
        0.651070356785595,...
        0.586265421807269,...
        0.533424474824942,...
        0.490553517839280,...
        0.454661553851284,...
        0.423754584861621,...
        0.396835611870624,...
        0.373904634878293,...
        0.352967655885295,...
        0.335021673891297,...
        0.319069689896632,...
        0.304114704901634,...
        0.291153717905969,...
        0.279189729909970,...
        0.268222740913638,...
        0.257255751917306,...
        0.248282760920307,...
        0.239309769923308,...
        0.231333777925975,...
        0.224354784928309,...
        0.217375791930644,...
        0.210396798932978,...
        0.204414804934978,...
        0.198432810936979,...
        0.193447815938646,...
        0.188462820940313];
    
    % quantizer parameters
    par.lsb = lsb_list(par.L-1)/sqrt(2*par.B); % least significant bit    
    par.clip_lvl = par.lsb*par.L/2; % clipping level
    par.labels = par.lsb *((0:par.L-1) - (par.L-1)/2); % uniform quantization labels
    par.thresholds = [-10^100, bsxfun(@minus, par.labels(:,2:end), par.lsb/2), 10^100];	% uniform quantization thresholds
    par.alpha = sqrt(2*par.B*sum(par.labels.^2.* ... 
        (normcdf(par.thresholds(2:end)*sqrt(2*par.B)) ...
        -normcdf(par.thresholds(1:end-1)*sqrt(2*par.B)))))^-1; % normalization constant
    par.labels = par.alpha*par.labels; % quantizer labels
    par.bussgang = par.alpha*par.lsb*sqrt(par.B/pi)*sum(exp(-par.B*par.lsb^2*((1:par.L-1)-par.L/2).^2)); % Bussgang gain
    
    % clipping and quantization
    par.clipper = @(x) max(min(x,par.clip_lvl-par.lsb/1e5),-(par.clip_lvl-par.lsb/1e5)); % clipper
    if mod(par.L,2) == 0
        par.quantizer = @(x) par.alpha * (par.lsb*floor(par.clipper(x)/par.lsb) + par.lsb/2); % midrise quantizer (without clipping)
    else
        par.quantizer = @(x) par.alpha * par.lsb*floor(par.clipper(x)/par.lsb + 1/2); % midtread quantizer (without clipping)
    end
    par.quantizer = @(x) par.quantizer(par.clipper(real(x))) + 1i*par.quantizer(par.clipper(imag(x))); % quantizer
    
    % -- start simulation

    % track simulation time
    time_elapsed = 0; tic;

    % trials loop
    for t=1:par.trials

        % generate random bit stream
        b = randi([0 1],par.U,par.bps);

        % generate transmit symbols
        idx = bi2de(b,'left-msb')+1;
        s = par.symbols(idx).';

        % generate iid Gaussian channel matrix & noise vector
        n = sqrt(0.5)*(randn(par.U,1)+1i*randn(par.U,1));
        H = sqrt(0.5)*(randn(par.U,par.B)+1i*randn(par.U,par.B));

        % channel estimation error
        if par.relerr > 0
            Hhat = sqrt(1-par.relerr)*H + sqrt(par.relerr/2)*(randn(par.U,par.B)+1i*randn(par.U,par.B));
        else
            Hhat = H;
        end

        % algorithm loop
        for pp=1:length(par.precoder)

            % noise-independent precoders
            switch (par.precoder{pp})
                case 'MRT_inf' % MRT precoding (inf. res.)
                    [x, beta] = MRT(s,Hhat);
                case 'MRT' % MRT precoding (quantized)
                    [z, beta] = MRT(s,Hhat);
                    x = par.quantizer(z); 
                    beta = beta/par.bussgang;
                case 'ZF_inf' % ZF precoding (inf. res.)
                    [x, beta] = ZF(s,Hhat); 
                case 'ZF' % ZF precoding (quantized)
                    [z, beta] = ZF(s, Hhat);
                    x = par.quantizer(z); 
                    beta = beta/par.bussgang;
            end     

            % SNR loop
            for k=1:length(par.SNRdB_list)

                % set noise variance
                N0 = 10.^(-par.SNRdB_list(k)/10);

                % noise-dependent precoders
                switch (par.precoder{pp})
                    case 'WF_inf'  % WF precoding (inf. res.)
                        [x, beta] = WF(s,Hhat,N0);
                    case 'WF'  % WF precoding (quantized)
                        [z, beta] = WF(s,Hhat,N0);
                        x = par.quantizer(z); 
                        beta = beta/par.bussgang; 
                    case {'SDR1', 'SDRr'} 
                        if par.L == 2
                            if t == 1 && k == 1 && par.B > 16
                                warning('SDR has high complexity for large systems. Run SDR for small systems only.');
                            end
                            if strcmpi(par.precoder{pp}, 'SDR1') % SDR with rank-one approximation
                                [x, beta, x_random, beta_random] = SDR(s,Hhat,N0);
                            elseif strcmpi(par.precoder{pp}, 'SDRr') % SDR with randomization
                                x = x_random; beta = beta_random; 
                            end
                        else
                            error('SDR: only 1 bit (L=2) supported!');
                        end
                    case 'SQUID' % squared inifinity-norm relaxation with Douglas-Rachford splitting
                        if par.L == 2
                            if t == 1 && k == 1
                                warning('Default parameters used for SQUID. Tune parameters for best results!');
                            end
                            [x, beta] = SQUID(s,Hhat,N0);    
                        else
                            error('SQUID: only 1 bit (L=2) supported!');
                        end
                    case 'SP' % sphere precoding
                        if par.L == 2
                            if t == 1 && k == 1 && par.B > 16
                                warning('SP has high complexity for large systems. Run SP for small systems only.');
                            end
                            [x, beta] = SP(s,Hhat,N0);
                        else
                            error('SP: only 1 bit (L=2) supported!');
                        end
                    case 'BB-1' % branch-and-bound precoding
                        if par.L == 2
                            if t == 1 && k == 1 && par.B > 16
                                warning('BB-1 has high complexity for large systems. Run BB-1 for small systems only.');
                            end
                            [x, beta] = BB1(s,Hhat,N0);
                        else
                            error('BB-1: only 1 bit (L=2) supported!');
                        end
                    case 'EXS' % exhaustive search
                        if par.L == 2
                            if t == 1 && k == 1 && par.B > 16
                                warning('EXS has high complexity for large systems. Run EXS for small systems only.');
                            end
                            [x, beta] = EXS(s,Hhat,N0);  
                        else
                            error('EXS: only 1 bit (L=2) supported!');
                        end
                end

                % transmit data over noisy channel
                Hx = H*x;
                y = Hx + sqrt(N0)*n;

                % extract maximum instantaneous transmitted and received power
                res.TxMaxPower(pp,k) = max(res.TxMaxPower(pp,k), sum(abs(x).^2));
                res.RxMaxPower(pp,k) = max(res.RxMaxPower(pp,k), sum(abs(Hx).^2)/par.U);

                % extract average transmitted and received power
                res.TxAvgPower(pp,k) = res.TxAvgPower(pp,k) + sum(abs(x).^2);
                res.RxAvgPower(pp,k) = res.RxAvgPower(pp,k) + sum(abs(Hx).^2)/par.U;

                % scale received signal at the UEs (not needed for PSK)
                shat = beta*y; 

                % UE-side nearest-neighbor detection
                [~,idxhat] = min(abs(shat*ones(1,length(par.symbols))-ones(par.U,1)*par.symbols).^2,[],2); 
                bhat = par.bits(idxhat,:);

                % -- compute error metrics
                err = (idx~=idxhat); % check for symbol errors
                res.VER(pp,k) = res.VER(pp,k) + any(err); % vector error rate
                res.SER(pp,k) = res.SER(pp,k) + sum(err)/par.U; % symbol error rate
                res.BER(pp,k) = res.BER(pp,k) + sum(sum(b~=bhat))/(par.U*par.bps); % bit error rate

                % save estimated symbols (if number of trials not too large)
                if par.trials <= 1e3
                    shat_list(:,pp,k,t) = shat;
                end

            end % SNR loop

        end % algorithm loop

        % keep track of simulation time
        if toc>10
            time=toc;
            time_elapsed = time_elapsed + time;
            fprintf('estimated remaining simulation time: %3.0f min.\n',time_elapsed*(par.trials/t-1)/60);
            tic
        end

    end % trials loop

    % normalize results
    res.VER = res.VER/par.trials;
    res.SER = res.SER/par.trials;
    res.BER = res.BER/par.trials;
    res.TxAvgPower = res.TxAvgPower/par.trials;
    res.RxAvgPower = res.RxAvgPower/par.trials;
    res.time_elapsed = time_elapsed;

    % -- show results

    if par.plot

        % marker style and color
        marker_style = {'o-','s--','v-.','+:','<-','>--','x-.','^:','*-','d--','h-.','p:'};
        marker_color = [...
            0.0000    0.4470    0.7410;...
            0.8500    0.3250    0.0980;...
            0.9290    0.6940    0.1250;...
            0.4940    0.1840    0.5560;...
            0.4660    0.6740    0.1880;...
            0.3010    0.7450    0.9330;...
            0.6350    0.0780    0.1840;...
            0.7500    0.7500    0.0000;...
            0.7500    0.0000    0.7500;...
            0.0000    0.5000    0.0000;...
            0.0000    0.0000    1.0000;...
            1.0000    0.0000    0.0000];
        
        % legends
        precoder_legend = par.precoder;
        for pp = 1:length(par.precoder)
            if strcmpi(precoder_legend{pp}, 'MRT_inf')
                precoder_legend{pp} = 'MRT (inf. res.)';
            elseif strcmpi(precoder_legend{pp}, 'ZF_inf')
                precoder_legend{pp} = 'ZF (inf. res.)';
            elseif strcmpi(precoder_legend{pp}, 'WF_inf')
                precoder_legend{pp} = 'WF (inf. res.)';
            end
        end

        % plot received symbol constellation (for highest SNR value)
        if par.trials <= 1e3

            if length(par.precoder)==1
                nd = 1;
            elseif length(par.precoder)<=6
                nd = 2;
            elseif length(par.precoder)<=9
                nd = 3;
            elseif length(par.precoder)<=12
                nd = 4;
            end
            md = ceil(length(par.precoder)/nd);

            figure('Name', 'Const.'); clf;
            for pp = 1:length(par.precoder)
                subplot(md,nd,pp); hold all;
                plot(reshape(shat_list(:,pp,end,:),1,[]),'*', 'color', marker_color(pp,:),'markersize',7);
                plot(par.symbols, 'ko','MarkerSize',7);
                axis(max(abs(reshape(shat_list(:,:,end,:),1,[])))*[-1 1 -1 1]); 
                axis square; box on;
                title(precoder_legend{pp},'fontsize',12);
                xlabel(['P_{avg}= ',num2str(10*log10(res.TxAvgPower(pp)),'%0.2f'),' dB',...
                    ' and P_{max}= ',num2str(10*log10(res.TxMaxPower(pp)),'%0.2f'),' dB'],'fontsize',12);
            end

        end

        % plot BER
        figure('name','BER');
        for pp=1:length(par.precoder)
            semilogy(par.SNRdB_list,res.BER(pp,:),marker_style{pp},'color',marker_color(pp,:),'LineWidth',2); hold on;
        end
        grid on; box on;
        xlabel('SNR [dB]','FontSize',12)
        ylabel('bit error rate (BER)','FontSize',12);
        if length(par.SNRdB_list) > 1
            axis([min(par.SNRdB_list) max(par.SNRdB_list) 1e-4 1]);
        end
        legend(precoder_legend,'FontSize',12,'location','southwest')
        set(gca,'FontSize',12);

    end

    fprintf('\nsimulation has finished!\n\n');

    % -- save results

    if par.save
        save([par.simName],'par','res');
        if par.plot
            print('-depsc',[par.simName '.eps' ]);
        end
    end

end


