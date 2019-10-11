warning off;

pkg load signal;
pkg load parallel;
pkg load io;

file_path = fileparts(mfilename('fullpath'));

addpath([file_path '/../../code/dependencies/eeglab_lossless'], ...
  [file_path '/../../code/dependencies/matlog'], ...
  [file_path '/../../code/tools']);
cd '/scratch/tk11br/Face13/';

% eeglab auto loads the path correctly instead of shotgun blasting with
% addpath(genpath(<>)) as we were doing prior
if ~exist('EEG', 'var')
  eeglab;
end
% Use matlog disp function override
logging_override_disp(true);
% Use matlog INFO level debugging
logging_set_log_level('INFO')

% Don't run with traditional but enable some of the options
save_default_options ('-mat-binary');
confirm_recursive_rmdir(false);

% This makes | and & || and && in earlier version of Octave where
% | and & dont short curcuit by default
if exist('do_braindead_shortcircuit_evaluation', 'builtin')
    do_braindead_shortcircuit_evaluation(true);
end

% Options
pop_editoptions('option_savetwofiles', 1,'option_single',0);

%% SCRIPT DESCRIPTION
% This script is loads the results of a preliminary ICA and uses the
% standard deviation of the components to flag and remove data time that
% does not fit a well behaved model. This will help make the next
% components stronger. The log likelihood of the model is also flagged for
% reference. Sections marked for high SD often have low log likelihoods
% as well. It then prepares the required parameter files for the parrallel amicas ABC.
%
%% From Config          key_strswap         Description
%-----------------------------------------------------------------------------------------------------------------------------
%  data_path =          derivatives/BIDS-Lossless-EEG           Path to input and output data files assuming cd = work_path
%  recur_sec =          1         Recurrence (sec) for artifact detection epoching (e.g. .3)
%  limit_sec =          [0 1]         Limits (sec) for artifact detection epoching (e.g. [-.3 .3])
%  sd_t_meth =          q         Method used for flagging epochs (e.g. 'q' (quantiles), or 'na' (default))
%  sd_t_vals  =         [.3 .7]         Percentage trim for confidence intervals during epoch standard deviation criteria (e.g. [.3 .7])
%  sd_t_o =             6            z threshold for flagging epochs during standard deviation criteria (e.g. 6)
%  sd_t_f_meth =        fixed       Fixed method used for flagging epochs (should be 'fixed')
%  sd_t_f_vals  =              Percentage trim for confidence intervals during epoch standard deviation criteria (e.g. [.3 .7], leave empty for 'fixed')
%  sd_t_f_o =           .2          z threshold for flagging epochs during fixed standard deviation criteria (e.g. .2)
%  out_path =           derivatives/BIDS-Lossless-EEG          Relative path to output data files assuming cd = work_path
%  min_gap_ms =         2000        Minimum time (ms) to allow between periods marked for rejection 
%  amica_param_file =   derivatives/BIDS-Lossless-EEG/code/misc/amica_default.param  template amicadefs.param file to modify
%  amica_threads_s04 =  8 number of threads to use for running s04a, s04b, s04c amica scripts (Default: 8)

%% LOAD SA DATASET
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Loads the batched EEG datafile and the AMICA output files. Since ICA is
% done on a channel subset the components need to be returned to the
% correct indicies.

% Load the EEG datafile
logging_log('INFO', 'Loading set file: ./sub-001/eeg/sub-001_task-faceFO_sa.set...');
tic;
EEG = pop_loadset('filepath','derivatives/BIDS-Lossless-EEG','filename','./sub-001/eeg/sub-001_task-faceFO_sa.set');
EEG = eeg_checkset( EEG );
logging_log('INFO', 'TIME TO: LOAD DATASET...');
toc

% Prepare returning components
EEG.icachansind = marks_label2index(EEG.marks.chan_info,{'manual','rank'},'indices','invert','on');
icatimeind = find(~EEG.marks.time_info(1).flags);

% Load AMICA Model 1
tic;
EEG.amica(1).models=loadmodout15('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_init');
EEG.icaweights=EEG.amica(1).models.W;
EEG.icasphere=EEG.amica(1).models.S(1:EEG.amica(1).models.num_pcs,:);
EEG=eeg_checkset(EEG);
logging_log('INFO', 'TIME TO: LOAD ICA INFO...');
toc
%% PASS EEGDATA THROUGH THE AMICA MATRIX
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%Uses the ICA weights and the channel data to recreate the ICA components.

tic;
% In place of EEG checkset
tmpdata = EEG.data(EEG.icachansind,:);
tmpindices = find(~sum(isnan(tmpdata)));
EEG.icaact = zeros(size(EEG.icaweights,1), size(tmpdata,2)); EEG.icaact(:) = NaN;
EEG.icaact(:,tmpindices) = (EEG.icaweights*EEG.icasphere)*tmpdata(:,tmpindices);
clear tmpdata;

%% LOG LIKELIHOOD FLAGS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%Creates marks based off of the log likelihood of the ICA model to the data.
% Create initial log likelihood marks

logl_init_flags=zeros(size(EEG.data(1,:)));
logl_init_flag_inds=marks_label2index(EEG.marks.time_info,{'manual'},'indices','invert','on');
logl_init_flags(logl_init_flag_inds)=(EEG.amica(1).models.Lt-min(EEG.amica(1).models.Lt))/(max(EEG.amica(1).models.Lt)-min(EEG.amica(1).models.Lt));

EEG.marks=marks_add_label(EEG.marks,'time_info', ...
	{'logl_init',[1,0.45,0],logl_init_flags});
logging_log('INFO', 'TIME TO: RECREATE ICA COMPONENTS...');
toc

% Window the continous Data
logging_log('INFO', 'Windowing the continous data...');
tic;
EEG=marks_continuous2epochs(EEG,'recurrence',1,'limits',[0 1]);
logging_log('INFO', 'TIME TO: WINDOW THE CONTINUOUS DATA...');
toc
%% CALCULATE ICAACT SD
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Calculates the IC standard Deviation by epoch window. Flags windows with
% too much standard deviation.

% Calculate IC sd by window
logging_log('INFO', 'Calculating the IC sd array for window criteria...');
tic;
epoch_inds=marks_label2index(EEG.marks.time_info,{'manual'},'indexes','invert','on');
[EEG,icaact_sd1_t]=chan_variance(EEG,'data_field','icaact', ...
		'epoch_inds',epoch_inds, ...
		'plot_figs','off');

% Create the windowing sd criteria
logging_log('INFO', 'Assessing window icaact sd distributions...')
[~,flag_t_inds]=marks_array2flags(icaact_sd1_t, ...
    'flag_dim','col', ...
    'init_method','q', ...
    'init_vals',[.3 .7], ...
    'init_crit',6, ...
    'flag_method','fixed', ...
    'flag_vals',[  ], ...
    'flag_crit',.2, ...
    'plot_figs','off');

% Update marks rejection structure
logging_log('INFO', 'Updating latflaginfo structure...');
icsd_epoch_flags=zeros(size(EEG.data(1,:,:)));
icsd_epoch_flags(1,:,epoch_inds(flag_t_inds))=1;
icsd_epoch_flags=padflags(EEG,icsd_epoch_flags,1,'value',.5);
EEG.marks=marks_add_label(EEG.marks,'time_info', ...
	{'ic_sd1',[.4,.6,.6],icsd_epoch_flags});
logging_log('INFO', 'TIME TO: UPDATE REJECTION STRUCTURE WITH IC SD MARKS...');
toc

% Concat the windowed data back to continuous
logging_log('INFO', 'Concatenating windowed data...');
tic;
EEG=marks_epochs2continuous(EEG);
EEG=eeg_checkset(EEG,'eventconsistency');
logging_log('INFO', 'TIME TO: CONCATENATE THE WINDOWED DATA INTO CONTINUOUS DATA...');
toc
%% FLAG GAPS
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Flags small gaps between rejection flags so that there are not as many
% short segments to be analyzed

% Mark any flag gaps < 2 sec.
tic;
EEG=pop_marks_flag_gap(EEG,{'manual','mark_gap','ic_sd1'}, ...
                            2000,'mark_gap',[.8,.8,.8],'offsets',[0 0],'ref_point','both');

%%COMBINE MARKS STRUCTURE INTO MANUAL FLAGS...
EEG=pop_marks_merge_labels(EEG,'time_info',{'manual','ic_sd1','mark_gap'},'target_label','manual');
logging_log('INFO', 'TIME TO: FLAG GAPS AND COMBINE MARKS STRUCTURE INTO MANUAL FLAGS...');
toc
%% SAVE compart_data.set FILE
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% A saved copy is made before the file is purged to its ready for ICA
% version.

tic;
logging_log('INFO', 'Saving file: ./sub-001/eeg/sub-001_task-faceFO_compart_data.set...');
EEG = pop_saveset( EEG, 'filename','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_compart_data.set');
logging_log('INFO', 'TIME TO: SAVE compart_data FILE...');
toc;
%% SAVE compart_data_purge FILE
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% All EEG parts associated with ICA need to be cleared as models seem to
% adapt based on previous data. Old and New flagged channels/time need to
% be purged again in preparation of ICA.

% Clearing ICA Data
EEG.icaact = [];
EEG.icawinv = [];
EEG.icasphere = [];
EEG.icaweights = [];
EEG.icachansind = [];
EEG.amica = []; 
logging_log('INFO', 'ICA data Reset');

% Removing Flagged Channels
tic;
sprintf('%s','Purging flagged channels...\n');
EEG=pop_marks_select_data(EEG,'channel marks',[],'labels',{'manual','rank'},'remove','on');
EEG=pop_marks_select_data(EEG,'time marks',[],'labels',{'manual'},'remove','on');
EEG=eeg_checkset(EEG);
logging_log('INFO', 'TIME TO: PURGE DATA...');
toc;

% Saving File to enter next ICAs
logging_log('INFO', 'Saving the Param files');
sprintf('%s','Saving file: ./sub-001/eeg/sub-001_task-faceFO_compart_data_purge.set...\n');
EEG = pop_saveset( EEG, 'filename','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_compart_data_purge.set');

% Save diagnostic arrays
try OCTAVE_VERSION;
    save('-mat7-binary','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_icaact_sd1_t.mat','icaact_sd1_t');
catch
    save('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_icaact_sd1_t.mat','icaact_sd1_t');
end

%% SAVE AMICA PARAMETER FILES
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% A parameter file need to be made for each of the ICAs running after this
% script. In This case AMICA A, B and C are run.

tic;
% A
% Saving AMICA Parameter File
swapstr=file_strswap('derivatives/BIDS-Lossless-EEG/code/misc/amica_default.param', ...
			'[repstr_fdt_fname]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_compart_data_purge.fdt', ...
			'[repstr_outpath]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_A', ...
			'[repstr_nbchan]', num2str(EEG.nbchan), ...
			'[repstr_pnts]', sprintf('%12.0f',EEG.pnts), ...
            '[repstr_tpp]', '8', ...
			'[repstr_pca]', num2str(EEG.nbchan));
fidparam=fopen('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_A.param','w');
fprintf(fidparam,'%s',swapstr);
fclose(fidparam);

% B
% Saving AMICA Parameter File
swapstr=file_strswap('derivatives/BIDS-Lossless-EEG/code/misc/amica_default.param', ...
			'[repstr_fdt_fname]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_compart_data_purge.fdt', ...
			'[repstr_outpath]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_B', ...
			'[repstr_nbchan]', num2str(EEG.nbchan), ...
			'[repstr_pnts]', sprintf('%12.0f',EEG.pnts), ...
            '[repstr_tpp]', '8', ...
			'[repstr_pca]', num2str(EEG.nbchan));
fidparam=fopen('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_B.param','w');
fprintf(fidparam,'%s',swapstr);
fclose(fidparam);

% C
% Saving AMICA Parameter File
swapstr=file_strswap('derivatives/BIDS-Lossless-EEG/code/misc/amica_default.param', ...
			'[repstr_fdt_fname]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_compart_data_purge.fdt', ...
			'[repstr_outpath]','derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_C', ...
			'[repstr_nbchan]', num2str(EEG.nbchan), ...
			'[repstr_pnts]', sprintf('%12.0f',EEG.pnts), ...
            '[repstr_tpp]', '8', ...
			'[repstr_pca]', num2str(EEG.nbchan));
fidparam=fopen('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_C.param','w');
fprintf(fidparam,'%s',swapstr);
fclose(fidparam);

%% Create the Amica Output Folder
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Needed for MPI jobs on cluster. Otherwise race effect will occur.

[~] = rmdir('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_A','s');
[~] = rmdir('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_B','s');
[~] = rmdir('derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_C','s');


mkdir 'derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_A';
mkdir 'derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_B';
mkdir 'derivatives/BIDS-Lossless-EEG/./sub-001/eeg/sub-001_task-faceFO_amicaout_C';

logging_log('INFO', 'TIME TO: CREATE AMICA PARAMETER FILES...');
toc

% FINISH
logging_log('INFO', '***********COMPART DATA COMPLETE!**********');
logging_log('INFO', 'Scheduler: sbatch');
print_chan_sample(EEG);
